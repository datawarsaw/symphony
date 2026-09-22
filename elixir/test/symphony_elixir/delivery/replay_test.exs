defmodule SymphonyElixir.Delivery.ReplayTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Delivery.{Git, Replay}
  alias SymphonyElixir.Test.DeliveryFixtures

  @base_content "l1\nl2\nl3\nl4\nl5\nl6\n"

  setup do
    repo = DeliveryFixtures.init_repo()
    on_exit(fn -> DeliveryFixtures.cleanup(repo) end)

    base = DeliveryFixtures.commit_file(repo, "lib/thing.ex", @base_content, "B: base")

    feature =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l2\n", "l2-fixed\n"), "F: fix")

    # accepted artifact lives in the object store; main restarts at the base
    DeliveryFixtures.reset_hard(repo, base)

    %{repo: repo, base: base, feature: feature}
  end

  test "an invalid base sha preserves the original git failure and leaves no scratch residue", %{
    repo: repo,
    feature: feature
  } do
    scratches = scratch_paths()

    assert {:error, {:git_failed, _, "fatal: invalid reference: deadbeef" <> _}} =
             Replay.cherry_pick(repo, [feature], "deadbeef")

    assert scratch_paths() -- scratches == []
  end

  test "an uncreatable scratch path preserves the original git failure and touches nothing", %{
    repo: repo,
    feature: feature
  } do
    parent = Path.join(System.tmp_dir!(), "replay_blocked_#{:erlang.unique_integer([:positive])}")
    File.write!(parent, "a file, not a directory")
    on_exit(fn -> File.rm(parent) end)

    assert {:error, {:git_failed, _, _}} =
             Replay.cherry_pick(repo, [feature], "deadbeef", scratch_dir: Path.join(parent, "scratch"))

    assert File.read!(parent) == "a file, not a directory"
  end

  test "a conflicting caller scratch path is never cleaned up", %{repo: repo, feature: feature} do
    caller = Path.join(System.tmp_dir!(), "replay_caller_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(caller)
    precious = Path.join(caller, "precious.txt")
    File.write!(precious, "keep me")
    on_exit(fn -> File.rm_rf(caller) end)

    assert {:error, {:git_failed, _, _}} = Replay.cherry_pick(repo, [feature], "deadbeef", scratch_dir: caller)
    assert File.exists?(precious), "content the tool never created must survive a failed replay"
  end

  test "a successful replay leaves no scratch behind", %{repo: repo, base: base, feature: feature} do
    scratches = scratch_paths()

    assert {:ok, %{replayed_shas: [replayed], base: ^base}} = Replay.cherry_pick(repo, [feature], base)
    assert {:ok, fixed_blob} = Git.path_blob(repo, replayed, "lib/thing.ex")
    assert {:ok, base_blob} = Git.path_blob(repo, base, "lib/thing.ex")
    assert fixed_blob != base_blob
    assert scratch_paths() -- scratches == []
  end

  test "a conflicting replay reports the conflict and leaves no scratch behind", %{repo: repo, base: base, feature: feature} do
    # touches the same line the accepted feature touches, so the pick conflicts
    _conflict =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l2\n", "l2-main\n"), "U: conflict")

    fresh = DeliveryFixtures.head(repo)
    scratches = scratch_paths()

    assert {:error, {:cherry_pick_conflict, %{failing_sha: failed, conflicting_paths: ["lib/thing.ex"]}}} =
             Replay.cherry_pick(repo, [feature], fresh)

    assert failed == feature
    assert scratch_paths() -- scratches == []
  end

  defp scratch_paths, do: Path.wildcard(Path.join(System.tmp_dir!(), "symphony_delivery_replay_*"))
end
