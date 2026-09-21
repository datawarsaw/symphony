defmodule SymphonyElixir.Delivery.Replay do
  @moduledoc """
  Dry-run scratch replay of an accepted artifact onto a fresh main.

  This is the only module in the delivery namespace that writes to the
  repository, and it does so only when the caller explicitly asks for a
  replay (the `--replay` flag on the preflight task). The mechanism:

    1. `git worktree add --detach` a throwaway worktree pinned to the
       supplied fresh main sha.
    2. `git cherry-pick` each accepted commit, in accepted order.
    3. Report either the replayed commit shas or, on conflict, the
       conflicting paths.
    4. Always remove the worktree afterwards — success, conflict, or crash.

  The scratch worktree lives under the system temp directory, never inside
  the repository, and it never moves a ref: the cherry-pick runs on a
  detached HEAD inside the worktree.
  """

  alias SymphonyElixir.Delivery.Git

  @type repo :: Git.repo()
  @type sha :: Git.sha()

  @type result ::
          {:ok, %{replayed_shas: [sha()], base: sha()}}
          | {:error, {:cherry_pick_conflict, %{failing_sha: sha(), conflicting_paths: [String.t()]}}}
          | {:error, term()}

  @doc """
  Cherry-picks `shas` (in order) onto `base_sha` inside a scratch worktree.

  Returns the replayed commit shas oldest-first, or the conflicting paths if
  any pick fails to merge. The worktree is removed in all outcomes.
  """
  @spec cherry_pick(repo(), [sha()], sha(), keyword()) :: result()
  def cherry_pick(repo, shas, base_sha, opts \\ []) do
    scratch = scratch_dir(opts)

    try do
      with :ok <- add_worktree(repo, scratch, base_sha),
           {:ok, replayed} <- pick_all(repo, scratch, shas) do
        {:ok, %{replayed_shas: Enum.reverse(replayed), base: base_sha}}
      end
    after
      cleanup_worktree(repo, scratch)
    end
  end

  defp scratch_dir(opts) do
    case Keyword.get(opts, :scratch_dir) do
      nil ->
        unique = :erlang.unique_integer([:positive])
        Path.join(System.tmp_dir!(), "symphony_delivery_replay_#{unique}")

      dir ->
        Path.absname(dir)
    end
  end

  defp add_worktree(repo, scratch, base_sha) do
    case Git.run(repo, ["worktree", "add", "--detach", scratch, base_sha]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp pick_all(repo, scratch, shas) do
    Enum.reduce_while(shas, {:ok, []}, fn sha, {:ok, acc} ->
      case pick_one(repo, scratch, sha) do
        {:ok, replayed} -> {:cont, {:ok, [replayed | acc]}}
        {:error, {:pick_failed, failed, _, _}} -> {:halt, conflict(scratch, failed)}
        error -> {:halt, error}
      end
    end)
  end

  defp pick_one(repo, scratch, sha) do
    case Git.run(scratch, ["cherry-pick", sha]) do
      {:ok, _} -> resolve_head(repo, scratch)
      {:error, {:git_failed, code, out}} -> {:error, {:pick_failed, sha, code, out}}
    end
  end

  defp resolve_head(repo, scratch) do
    case Git.run(scratch, ["rev-parse", "HEAD"]) do
      {:ok, head} -> Git.resolve_commit(repo, head)
      error -> error
    end
  end

  defp conflict(scratch, failing_sha) do
    case Git.run(scratch, ["diff", "--name-only", "--diff-filter=U"]) do
      {:ok, out} ->
        paths = out |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.sort()
        {:error, {:cherry_pick_conflict, %{failing_sha: failing_sha, conflicting_paths: paths}}}

      error ->
        error
    end
  end

  defp cleanup_worktree(repo, scratch) do
    _ = Git.run(scratch, ["cherry-pick", "--abort"])
    _ = Git.run(repo, ["worktree", "remove", "--force", scratch])
    _ = Git.run(repo, ["worktree", "prune"])
    File.rm_rf(scratch)
    :ok
  end
end
