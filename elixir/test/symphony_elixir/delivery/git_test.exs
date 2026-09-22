defmodule SymphonyElixir.Delivery.GitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Delivery.Git
  alias SymphonyElixir.Test.DeliveryFixtures

  @base_content "l1\nl2\nl3\nl4\nl5\nl6\n"

  setup do
    repo = DeliveryFixtures.init_repo()
    on_exit(fn -> DeliveryFixtures.cleanup(repo) end)

    base = DeliveryFixtures.commit_file(repo, "lib/thing.ex", @base_content, "B: base")

    feature =
      DeliveryFixtures.commit_file(repo, "lib/thing.ex", String.replace(@base_content, "l2\n", "l2-fixed\n"), "F: fix")

    %{repo: repo, base: base, feature: feature}
  end

  test "stable_patch_id matches a direct git patch-id run and leaves no temp file", %{repo: repo, feature: feature} do
    temps = patch_id_temps()

    assert {:ok, id} = Git.stable_patch_id(repo, feature)
    assert id == external_patch_id(repo, feature)
    assert patch_id_temps() -- temps == []
  end

  test "a commit whose diff produces no patch id errors structurally and leaves no temp file", %{repo: repo} do
    {_, 0} =
      System.cmd("git", ["-c", "safe.directory=#{repo}", "-C", repo, "commit", "--allow-empty", "-m", "E: empty"],
        cd: repo,
        stderr_to_stdout: true
      )

    empty = DeliveryFixtures.head(repo)
    temps = patch_id_temps()

    assert {:error, {:git_failed, 1, "git patch-id produced no id for " <> _}} = Git.stable_patch_id(repo, empty)
    assert patch_id_temps() -- temps == []
  end

  test "a spawn failure cannot leak the staged patch temp file", %{repo: repo, feature: feature} do
    Application.put_env(:symphony_elixir, :patch_id_runner, fn _dir, _file -> raise "spawn exploded" end)
    temps = patch_id_temps()

    assert_raise RuntimeError, "spawn exploded", fn -> Git.stable_patch_id(repo, feature) end
    assert patch_id_temps() -- temps == []
  after
    Application.delete_env(:symphony_elixir, :patch_id_runner)
  end

  test "a non-zero patch-id exit returns the structured git error and removes the temp file", %{
    repo: repo,
    feature: feature
  } do
    Application.put_env(:symphony_elixir, :patch_id_runner, fn _dir, _file -> {"boom", 42} end)
    temps = patch_id_temps()

    assert {:error, {:git_failed, 42, "boom"}} = Git.stable_patch_id(repo, feature)
    assert patch_id_temps() -- temps == []
  after
    Application.delete_env(:symphony_elixir, :patch_id_runner)
  end

  test "patch-id output with no id removes the temp file and errors structurally", %{repo: repo, feature: feature} do
    Application.put_env(:symphony_elixir, :patch_id_runner, fn _dir, _file -> {"", 0} end)
    temps = patch_id_temps()

    assert {:error, {:git_failed, 1, "git patch-id produced no id for " <> _}} = Git.stable_patch_id(repo, feature)
    assert patch_id_temps() -- temps == []
  after
    Application.delete_env(:symphony_elixir, :patch_id_runner)
  end

  # Recomputes the stable patch id outside the module under test, replicating
  # the canonicalization contract: pinned diff-tree flags, `git patch-id
  # --stable` on the staged patch text. Pins the output against accidental
  # algorithm drift.
  defp external_patch_id(repo, sha) do
    {:ok, patch} = Git.run(repo, ["diff-tree", "-p", "--root", "--no-renames", sha])
    dir = System.tmp_dir!()
    path = Path.join(dir, "external_patch_id_#{:erlang.unique_integer([:positive])}")
    File.write!(path, patch)

    try do
      case :os.type() do
        {:win32, _} ->
          {out, 0} =
            System.cmd("cmd", ["/c", "git patch-id --stable < #{Path.basename(path)}"], cd: dir, stderr_to_stdout: true)

          out |> String.split(" ") |> List.first()

        _ ->
          {out, 0} =
            System.cmd("sh", ["-c", "git patch-id --stable < \"$1\"", "sh", path], cd: dir, stderr_to_stdout: true)

          out |> String.split(" ") |> List.first()
      end
    after
      File.rm(path)
    end
  end

  defp patch_id_temps, do: Path.wildcard(Path.join(System.tmp_dir!(), "symphony_patch_id_*"))
end
