defmodule Mix.Tasks.Symphony.DeliveryPreflightTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.DeliveryPreflight
  alias SymphonyElixir.Delivery.ArtifactManifest
  alias SymphonyElixir.Test.DeliveryFixtures

  @base_content "l1\nl2\nl3\n"

  setup do
    Mix.Task.reenable("symphony.delivery_preflight")

    repo = DeliveryFixtures.init_repo()
    on_exit(fn -> DeliveryFixtures.cleanup(repo) end)

    base = DeliveryFixtures.commit_file(repo, "lib/thing.ex", @base_content, "B: base")

    feature =
      DeliveryFixtures.commit_changes(repo, "F: fix line 2", [
        {:write, "lib/thing.ex", String.replace(@base_content, "l2\n", "l2-fixed\n")}
      ])

    DeliveryFixtures.reset_hard(repo, base)

    %{repo: repo, base: base, feature: feature}
  end

  test "freeze writes a decodable manifest with --out", %{repo: repo, feature: feature} do
    out = Path.join(System.tmp_dir!(), "task_manifest_#{:erlang.unique_integer([:positive])}.json")

    output =
      capture_io(fn ->
        assert :ok = DeliveryPreflight.run(["freeze", feature, "--repo", repo, "--out", out])
      end)

    assert output =~ "froze 1 commit(s)"
    assert {:ok, manifest} = ArtifactManifest.load(out)
    assert manifest.artifact_kind == :single
    assert hd(manifest.commits).candidate_sha == feature
  end

  test "freeze prints manifest JSON to stdout without --out", %{repo: repo, feature: feature} do
    output =
      capture_io(fn ->
        assert :ok = DeliveryPreflight.run(["freeze", feature, "--repo", repo])
      end)

    assert {:ok, decoded} = ArtifactManifest.decode(output)
    assert hd(decoded.commits).candidate_sha == feature
  end

  test "preflight prints PROCEED and the evidence boundary on a clean replay", %{repo: repo, feature: feature} do
    manifest = manifest_file(repo, feature)

    output =
      capture_io(fn ->
        assert :ok =
                 DeliveryPreflight.run([
                   "preflight",
                   "--manifest",
                   manifest,
                   "--repo",
                   repo,
                   "--fresh-main",
                   DeliveryFixtures.head(repo),
                   "--replay"
                 ])
      end)

    assert output =~ "VERDICT: PROCEED"
    assert output =~ "not a semantic reviewer"
    assert output =~ "exact parent"
  end

  test "preflight exits {:shutdown, 1} on STOP", %{repo: repo, feature: feature} do
    manifest = manifest_file(repo, feature)

    _overlap =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l3\n", "l3-main\n"), "U: overlap")

    fresh = DeliveryFixtures.head(repo)

    output =
      capture_io(fn ->
        assert catch_exit(DeliveryPreflight.run(["preflight", "--manifest", manifest, "--repo", repo, "--fresh-main", fresh])) == {:shutdown, 1}
      end)

    assert output =~ "VERDICT: STOP"
  end

  test "preflight --json prints the report as JSON", %{repo: repo, feature: feature} do
    manifest = manifest_file(repo, feature)

    output =
      capture_io(fn ->
        assert :ok =
                 DeliveryPreflight.run([
                   "preflight",
                   "--manifest",
                   manifest,
                   "--repo",
                   repo,
                   "--fresh-main",
                   DeliveryFixtures.head(repo),
                   "--json"
                 ])
      end)

    assert {:ok, report} = Jason.decode(output)
    assert report["verdict"] == "proceed"
    assert report["classification"] == "exact_parent"
  end

  test "a hand-tampered reversed chain exits with a structured STOP, not a crash", %{repo: repo, feature: feature, base: base} do
    DeliveryFixtures.reset_hard(repo, feature)

    remediation =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l1\n", "l1-fixed\n"), "R: remediation")

    DeliveryFixtures.reset_hard(repo, base)

    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    tampered = %{manifest | commits: Enum.reverse(manifest.commits)}
    path = Path.join(System.tmp_dir!(), "task_manifest_#{:erlang.unique_integer([:positive])}.json")
    :ok = ArtifactManifest.save(tampered, path)
    on_exit(fn -> File.rm(path) end)

    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert catch_exit(DeliveryPreflight.run(["preflight", "--manifest", path, "--repo", repo, "--fresh-main", base])) ==
                   {:shutdown, 1}
        end)
      end)

    assert output =~ "lineage_broken"
  end

  test "preflight --json emits a decodable STOP report for tuple stop reasons", %{repo: repo, feature: feature, base: base} do
    DeliveryFixtures.reset_hard(repo, feature)

    remediation =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l1\n", "l1-fixed\n"), "R: remediation")

    DeliveryFixtures.reset_hard(repo, base)

    {:ok, manifest} = ArtifactManifest.build(repo, [feature, remediation])
    tampered = %{manifest | commits: Enum.reverse(manifest.commits)}
    path = Path.join(System.tmp_dir!(), "task_manifest_#{:erlang.unique_integer([:positive])}.json")
    :ok = ArtifactManifest.save(tampered, path)
    on_exit(fn -> File.rm(path) end)

    output =
      capture_io(fn ->
        assert catch_exit(DeliveryPreflight.run(["preflight", "--manifest", path, "--repo", repo, "--fresh-main", base, "--json"])) == {:shutdown, 1}
      end)

    assert {:ok, report} = Jason.decode(output)
    assert report["verdict"] == "stop"
    assert [reason] = report["stop_reasons"]
    assert reason =~ "lineage_broken"
    assert reason =~ feature
  end

  test "remote-truth stops when the artifact is absent from final main", %{repo: repo, feature: feature} do
    manifest = manifest_file(repo, feature)
    other = DeliveryFixtures.commit_file(repo, "docs/other.txt", "x\n", "U")

    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert catch_exit(
                   DeliveryPreflight.run([
                     "remote-truth",
                     "--manifest",
                     manifest,
                     "--repo",
                     repo,
                     "--final-main",
                     other
                   ])
                 ) == {:shutdown, 1}
        end)
      end)

    assert output =~ "STOP"
  end

  test "missing required option raises", %{repo: repo} do
    assert_raise Mix.Error, ~r/missing --manifest/, fn ->
      DeliveryPreflight.run(["preflight", "--repo", repo])
    end
  end

  test "unknown subcommand raises" do
    assert_raise Mix.Error, ~r/unknown subcommand/, fn ->
      DeliveryPreflight.run(["bogus"])
    end
  end

  defp manifest_file(repo, sha) do
    path = Path.join(System.tmp_dir!(), "task_manifest_#{:erlang.unique_integer([:positive])}.json")
    {:ok, manifest} = ArtifactManifest.build(repo, [sha])
    :ok = ArtifactManifest.save(manifest, path)
    path
  end
end
