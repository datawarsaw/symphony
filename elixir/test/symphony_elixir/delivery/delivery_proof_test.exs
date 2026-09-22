defmodule SymphonyElixir.Delivery.DeliveryProofTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Delivery.{ArtifactManifest, Git, Proof}
  alias SymphonyElixir.Test.DeliveryFixtures

  @base_content "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nl16\n"
  @feature_content "l1\nl2-fixed\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\nl16\n"
  @remediation_content "l1\nl2-fixed\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10-fixed\nl11\nl12\nl13\nl14\nl15\nl16\n"

  setup do
    chain = build_delivery_chain()
    on_exit(fn -> DeliveryFixtures.cleanup(chain.repo) end)
    chain
  end

  # ------------------------------------------------------------------
  # manifest freeze / round trip
  # ------------------------------------------------------------------

  test "freeze builds a single-commit manifest with the full schema", %{repo: repo, feature: feature, base: base} do
    assert {:ok, manifest} = ArtifactManifest.build(repo, [feature])
    assert manifest.artifact_kind == :single
    assert manifest.schema_version == 1
    assert [entry] = manifest.commits
    assert entry.candidate_sha == feature
    assert entry.parent_sha == base
    assert entry.commit_subject == "F: fix line 2"
    assert entry.changed_paths == ["docs/notes.txt", "lib/feature.ex"]
    assert is_binary(entry.stable_patch_id)
    assert is_map(entry.path_blobs)

    assert {:ok, decoded} = manifest |> ArtifactManifest.encode() |> ArtifactManifest.decode()
    assert decoded.commits == manifest.commits
    assert decoded.artifact_kind == manifest.artifact_kind
    assert decoded.cumulative == nil
  end

  test "freeze builds a cumulative manifest with ordered lineage", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    assert {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    assert manifest.artifact_kind == :cumulative

    cumulative = manifest.cumulative
    assert cumulative.feature_sha == feature
    assert cumulative.remediation_sha == remediation
    assert cumulative.original_parent_sha == base
    assert cumulative.ordered_patch_ids == Enum.map(manifest.commits, & &1.stable_patch_id)

    [_f_entry, r_entry] = manifest.commits
    assert r_entry.parent_sha == feature
    assert r_entry.changed_paths == ["docs/notes.txt", "lib/feature.ex"]
    assert r_entry.path_blobs["docs/notes.txt"] == nil, "deletion records an absent blob"

    json = ArtifactManifest.encode(manifest)
    assert json =~ ~s("artifact_kind": "cumulative")
    assert json =~ ~s("original_parent_sha": "#{base}")
    assert {:ok, decoded} = ArtifactManifest.decode(json)
    assert decoded.cumulative.ordered_patch_ids == cumulative.ordered_patch_ids
    assert decoded.commits == manifest.commits
  end

  test "freeze rejects merge commits, broken chains, and unknown shas", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    assert {:error, {:not_a_commit, "deadbeef"}} = ArtifactManifest.build(repo, ["deadbeef"])

    # reversed order: the remediation cannot precede its own feature
    assert {:error, {:broken_chain, _, _}} = ArtifactManifest.build(repo, [remediation, feature])

    # a merge commit can never be a frozen artifact: diverge main and merge
    DeliveryFixtures.reset_hard(repo, base)
    mainline = DeliveryFixtures.commit_file(repo, "docs/main-line.txt", "m\n", "M: main line commit")
    DeliveryFixtures.reset_hard(repo, base)
    side = DeliveryFixtures.commit_file(repo, "docs/side.txt", "s\n", "S: side branch commit")
    DeliveryFixtures.reset_hard(repo, mainline)
    merge = DeliveryFixtures.merge(repo, side)

    assert {:error, :merge_commit_rejected} = ArtifactManifest.build(repo, [merge])
  end

  test "self-check rejects a candidate missing from the repository", %{repo: repo, feature: feature} do
    other = DeliveryFixtures.init_repo()
    on_exit(fn -> DeliveryFixtures.cleanup(other) end)
    DeliveryFixtures.commit_file(other, "readme.md", "r\n", "init other")

    {:ok, manifest} = ArtifactManifest.build(repo, [feature])

    assert {:stop, report} = Proof.self_check(other, manifest)
    assert report.stop_reasons == [{:candidate_missing, feature}]
    assert report.verdict == :stop
  end

  test "self-check rejects a tampered patch-id", %{repo: repo, feature: feature} do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature])
    tampered_entry = %{hd(manifest.commits) | stable_patch_id: "0" <> hd(manifest.commits).stable_patch_id}
    tampered = %{manifest | commits: [tampered_entry]}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert [{:manifest_tampered, {sha, :stable_patch_id}}] = report.stop_reasons
    assert sha == feature
  end

  # ------------------------------------------------------------------
  # malformed lineage fails closed
  # ------------------------------------------------------------------

  test "a reversed cumulative chain stops instead of crashing", %{
    repo: repo,
    feature: feature,
    remediation: remediation
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    tampered = %{manifest | commits: Enum.reverse(manifest.commits)}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert report.verdict == :stop
    assert [{:lineage_broken, ^feature}] = report.stop_reasons
  end

  test "a duplicated chain entry stops instead of crashing", %{repo: repo, feature: feature, remediation: remediation} do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    entry = hd(manifest.commits)
    tampered = %{manifest | commits: [entry, entry]}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert [{:lineage_broken, ^feature}] = report.stop_reasons
  end

  test "a wrong-parent chain entry stops with lineage_broken", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    [feature_entry, remediation_entry] = manifest.commits
    tampered = %{manifest | commits: [feature_entry, %{remediation_entry | parent_sha: base}]}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert [{:lineage_broken, ^remediation}] = report.stop_reasons
  end

  test "a malformed chain with an extra entry stops on the first broken pair", %{
    repo: repo,
    feature: feature,
    remediation: remediation
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    [feature_entry, remediation_entry] = manifest.commits
    tampered = %{manifest | commits: [feature_entry, remediation_entry, feature_entry]}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert [{:lineage_broken, ^feature}] = report.stop_reasons
  end

  test "a tampered cumulative patch-id ordering stops", %{
    repo: repo,
    feature: feature,
    remediation: remediation
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    cumulative = %{manifest.cumulative | ordered_patch_ids: Enum.reverse(manifest.cumulative.ordered_patch_ids)}
    tampered = %{manifest | cumulative: cumulative}

    assert {:stop, report} = Proof.self_check(repo, tampered)
    assert [{:manifest_tampered, {:cumulative, :ordered_patch_ids}}] = report.stop_reasons
  end

  test "a supported cumulative manifest still passes self-check unchanged", %{
    repo: repo,
    feature: feature,
    remediation: remediation
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])

    assert {:ok, report} = Proof.self_check(repo, manifest)
    assert report.verdict == :proceed
    assert report.stop_reasons == []
  end

  # ------------------------------------------------------------------
  # preflight classifications
  # ------------------------------------------------------------------

  test "exact-parent replay is mechanically equivalent", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    report = Proof.run_preflight(repo, manifest, fresh_main: base, replay: true)

    assert report.verdict == :proceed
    assert report.classification == :exact_parent
    assert report.stop_reasons == []
    assert %{replayed_shas: [r1, r2]} = report.data
    assert r1 != feature and r2 != remediation
    assert Enum.any?(report.evidence, &(&1 =~ "tree ✓ (identical parent, tree proof required and passed)"))
    assert Enum.any?(report.evidence, &(&1 =~ "patch-id ✓ paths ✓ blobs ✓"))
  end

  test "transformed cherry-pick replay proves patch-id and blob equality with changed parent", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    _unrelated = DeliveryFixtures.commit_file(repo, "docs/unrelated.txt", "x\n", "U: unrelated main movement")
    fresh = DeliveryFixtures.head(repo)

    report = Proof.run_preflight(repo, manifest, fresh_main: fresh, replay: true)

    assert report.verdict == :proceed
    assert report.classification == :no_overlap
    assert %{replayed_shas: [r1, r2]} = report.data
    assert r1 != feature and r2 != remediation

    # changed parent, identical accepted blobs
    [_f_entry, r_entry] = manifest.commits
    assert {:ok, replayed_blob} = Git.path_blob(repo, r2, "lib/feature.ex")
    assert replayed_blob == r_entry.path_blobs["lib/feature.ex"]
    assert Enum.any?(report.evidence, &(&1 =~ "tree n/a (replay parent differs: transformed replay)"))
  end

  test "changed-path overlap stops before replay when replay is not requested", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    _overlap = DeliveryFixtures.commit_file(repo, "lib/feature.ex", String.replace(@base_content, "l5\n", "l5-main\n"), "U2: overlap")

    report = Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo))

    assert report.verdict == :stop
    assert report.classification == :changed_path_overlap
    assert :changed_path_overlap in report.stop_reasons
    assert report.data.overlap_paths == ["lib/feature.ex"]
    assert Map.has_key?(report.data, :replayed_shas) == false
    assert Enum.any?(report.evidence, &(&1 =~ "review decision, not a tool verdict"))
  end

  test "cherry-pick conflict stops with conflicting paths as replay evidence", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)

    _conflict =
      DeliveryFixtures.commit_file(repo, "lib/feature.ex", String.replace(@base_content, "l2\n", "l2-main\n"), "U3: conflicting")

    report = Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo), replay: true)

    assert report.verdict == :stop
    assert :changed_path_overlap in report.stop_reasons
    assert :replay_conflict in report.stop_reasons
    assert %{failing_sha: failed, conflicting_paths: ["lib/feature.ex"]} = report.data.replay_conflict
    assert failed == feature, "the first pick is the one that conflicts"
  end

  test "clean replay over overlapped main still stops on blob mismatch", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)

    # touches the artifact path outside every artifact hunk's context window:
    # the replay merges cleanly with equal patch ids, yet the resulting blob
    # no longer equals the accepted blob
    _far =
      DeliveryFixtures.commit_file(repo, "lib/feature.ex", String.replace(@base_content, "l16\n", "l16-main\n"), "U4: far hunk")

    report = Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo), replay: true)

    assert report.verdict == :stop
    assert :changed_path_overlap in report.stop_reasons
    assert :replay_blob_mismatch in report.stop_reasons

    blob_details = report.data.replay_mismatches |> List.flatten() |> Enum.filter(&(&1.kind == :blob))
    assert Enum.any?(blob_details, &(&1.detail =~ "lib/feature.ex"))
  end

  test "superseded candidate stops when equivalent patches are already in main", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    f_copy = DeliveryFixtures.cherry_pick(repo, feature)
    _r_copy = DeliveryFixtures.cherry_pick(repo, remediation)

    report = Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo))

    assert report.verdict == :stop
    assert report.classification == :superseded
    assert :superseded in report.stop_reasons
    assert f_copy != feature
    assert length(report.data.superseded_patch_ids) == 2
  end

  test "remediation-only misuse is rejected on a main that lacks the feature", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    # freeze ONLY the remediation commit and try to prove it against a main
    # that never saw the feature: the accepted parent (the feature) is missing
    {:ok, manifest} = ArtifactManifest.build(repo, [remediation])

    report = Proof.run_preflight(repo, manifest, fresh_main: base, replay: true)

    assert report.verdict == :stop
    assert report.classification == :main_not_descendant
    assert :main_not_descendant in report.stop_reasons
    assert Enum.any?(report.evidence, &(&1 =~ feature)), "the report names the missing accepted parent"
  end

  test "cumulative artifact is proven as a unit: partially merged main stops", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    _f_copy = DeliveryFixtures.cherry_pick(repo, feature)

    report = Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo))

    assert report.verdict == :stop
    assert report.classification == :partially_superseded
    assert :partially_superseded in report.stop_reasons
    assert length(report.data.superseded_patch_ids) == 1
  end

  test "main moves between checks and the baseline is never silently updated", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    unchanged = Proof.drift(repo, base, base)
    assert unchanged.verdict == :proceed
    assert unchanged.data.relation == :unchanged

    DeliveryFixtures.reset_hard(repo, base)
    _u = DeliveryFixtures.commit_file(repo, "docs/unrelated.txt", "x\n", "U")
    moved = DeliveryFixtures.head(repo)

    advanced = Proof.drift(repo, base, moved)
    assert advanced.verdict == :proceed
    assert advanced.data.relation == :advanced
    assert advanced.data.moved_by == 1
    assert Enum.any?(advanced.evidence, &(&1 =~ "BASELINE MOVED"))

    # rewound main
    DeliveryFixtures.reset_hard(repo, base)
    rewound = Proof.drift(repo, moved, DeliveryFixtures.head(repo))
    assert rewound.verdict == :stop
    assert :main_rewound in rewound.stop_reasons

    # diverged main
    _v = DeliveryFixtures.commit_file(repo, "docs/divergent.txt", "v\n", "V")
    diverged = Proof.drift(repo, moved, DeliveryFixtures.head(repo))
    assert diverged.verdict == :stop
    assert :main_diverged in diverged.stop_reasons

    # no hidden state: the manifest file is byte-identical after every run
    path = manifest_path()
    :ok = ArtifactManifest.save(manifest, path)
    before = File.read!(path)
    Proof.run_preflight(repo, manifest, fresh_main: DeliveryFixtures.head(repo))
    assert File.read!(path) == before
  end

  # ------------------------------------------------------------------
  # remote truth
  # ------------------------------------------------------------------

  test "post-merge proof passes with exact containment after a fast-forward merge", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    DeliveryFixtures.merge(repo, feature)
    final = DeliveryFixtures.merge(repo, remediation)

    report = Proof.remote_truth(repo, manifest, final)

    assert report.verdict == :proceed
    assert [%{mode: :exact}, %{mode: :exact}] = report.data.containers
    assert Enum.any?(report.evidence, &(&1 =~ "lib/feature.ex: blob unchanged since delivery"))
    assert Enum.any?(report.evidence, &(&1 =~ "docs/notes.txt: blob unchanged since delivery (absent)"))
  end

  test "post-merge proof passes for a transformed cherry-pick merge with ordered lineage", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    DeliveryFixtures.cherry_pick(repo, feature)
    final = DeliveryFixtures.cherry_pick(repo, remediation)

    report = Proof.remote_truth(repo, manifest, final)

    assert report.verdict == :proceed
    assert [%{mode: :equivalent}, %{mode: :equivalent}] = report.data.containers
    assert Enum.any?(report.evidence, &(&1 =~ "stable patch id equal"))
  end

  test "remote truth stops when the artifact was never merged", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    _u = DeliveryFixtures.commit_file(repo, "docs/unrelated.txt", "x\n", "U")

    report = Proof.remote_truth(repo, manifest, DeliveryFixtures.head(repo))

    assert report.verdict == :stop
    assert [{:remote_truth_not_contained, {sha, _patch_id}}] = report.stop_reasons
    assert sha == feature
  end

  test "remote truth stops when a transformed container is not blob-equivalent", %{
    repo: repo,
    base: base,
    feature: feature,
    remediation: remediation
  } do
    manifest = cumulative_manifest(repo, feature, remediation)

    DeliveryFixtures.reset_hard(repo, base)
    DeliveryFixtures.cherry_pick(repo, feature)
    _far = DeliveryFixtures.commit_file(repo, "lib/feature.ex", String.replace(@base_content, "l16\n", "l16-main\n"), "U4")
    DeliveryFixtures.cherry_pick(repo, remediation)

    report = Proof.remote_truth(repo, manifest, DeliveryFixtures.head(repo))

    assert report.verdict == :stop
    assert [{:remote_truth_mismatch, {_accepted, container}}] = report.stop_reasons
    assert container != remediation
    assert Enum.any?(report.evidence, &(&1 =~ "blob identity differs"))
  end

  # ------------------------------------------------------------------
  # comparator unit level
  # ------------------------------------------------------------------

  test "compare_entry flags a patch-id mismatch between different commits", %{
    repo: repo,
    base: base,
    feature: feature
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature])
    entry = hd(manifest.commits)
    unrelated = unrelated_commit(repo, base)

    assert {:mismatch, details} = Proof.compare_entry(repo, unrelated, entry)
    assert Enum.any?(details, &(&1.kind == :patch_id and &1.detail =~ "patch-id differs"))
    assert Enum.any?(details, &(&1.kind == :paths))
  end

  test "compare_entry proves equivalence for a transformed replay of the same patch", %{
    repo: repo,
    base: base,
    feature: feature
  } do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature])

    DeliveryFixtures.reset_hard(repo, base)
    _u = DeliveryFixtures.commit_file(repo, "docs/unrelated.txt", "x\n", "U")
    copy = DeliveryFixtures.cherry_pick(repo, feature)

    assert :equivalent = Proof.compare_entry(repo, copy, hd(manifest.commits))
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  defp build_delivery_chain do
    repo = DeliveryFixtures.init_repo()
    base = DeliveryFixtures.commit_file(repo, "lib/feature.ex", @base_content, "B: base feature file")

    feature =
      DeliveryFixtures.commit_changes(repo, "F: fix line 2", [
        {:write, "lib/feature.ex", @feature_content},
        {:write, "docs/notes.txt", "notes\n"}
      ])

    remediation =
      DeliveryFixtures.commit_changes(repo, "R: fix line 4 and drop notes", [
        {:write, "lib/feature.ex", @remediation_content},
        {:delete, "docs/notes.txt"}
      ])

    # accepted artifact lives in the object store; main restarts at the base
    DeliveryFixtures.reset_hard(repo, base)

    %{repo: repo, base: base, feature: feature, remediation: remediation}
  end

  defp cumulative_manifest(repo, feature, remediation) do
    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    manifest
  end

  defp unrelated_commit(repo, base) do
    DeliveryFixtures.reset_hard(repo, base)
    sha = DeliveryFixtures.commit_file(repo, "docs/unrelated.txt", "x\n", "U: unrelated")
    DeliveryFixtures.reset_hard(repo, base)
    sha
  end

  defp manifest_path, do: Path.join(System.tmp_dir!(), "manifest_#{:erlang.unique_integer([:positive])}.json")
end
