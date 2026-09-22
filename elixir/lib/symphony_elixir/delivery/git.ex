defmodule SymphonyElixir.Delivery.Git do
  @moduledoc """
  Read-only git shell-out primitives for delivery artifact integrity proofs.

  Every function in this module observes the repository without changing it:
  no refs move, nothing is checked out, no worktrees are created. The only
  repository-touching writer in the delivery namespace is
  `SymphonyElixir.Delivery.Replay`, which requires an explicit opt-in and
  operates inside a scratch worktree it removes afterwards.

  Diff-producing commands pin the diff configuration (algorithm, context,
  rename detection, colors) so that patch text — and therefore stable patch
  ids — is identical regardless of the caller's local git configuration.
  """

  @type repo :: String.t()
  @type sha :: String.t()

  @type git_error :: {:error, {:git_failed, non_neg_integer(), String.t()}}

  @doc """
  Runs a read-only git command in `repo` and returns its trimmed stdout.

  Any non-zero exit is returned as `{:error, {:git_failed, code, output}}`;
  nothing raises and nothing is retried.
  """
  @spec run(repo(), [String.t()]) :: {:ok, String.t()} | git_error()
  def run(repo, args) do
    case System.cmd("git", ["-c", "safe.directory=#{repo}" | args], cd: repo, stderr_to_stdout: true) do
      {out, 0} -> {:ok, trim(out)}
      {out, code} -> {:error, {:git_failed, code, trim(out)}}
    end
  end

  @doc """
  Resolves `sha` to a full 40-hex commit sha.

  Returns `{:error, :not_a_commit}` when the object is missing or is not a
  commit; any other git failure surfaces as `{:error, {:git_failed, _, _}}`.
  """
  @spec resolve_commit(repo(), String.t()) :: {:ok, sha()} | {:error, :not_a_commit} | git_error()
  def resolve_commit(repo, sha) do
    case run(repo, ["rev-parse", "--verify", "--quiet", "#{sha}^{commit}"]) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, {:git_failed, 1, _}} -> {:error, :not_a_commit}
      error -> error
    end
  end

  @doc """
  Reads identity and topology of one commit in a single git invocation.

  `parent_shas` is empty for a root commit and holds two or more entries
  exactly when the commit is a merge, so callers can reject merges before
  building artifacts from them.
  """
  @spec commit_info(repo(), sha()) ::
          {:ok,
           %{
             sha: sha(),
             parent_shas: [sha()],
             tree_sha: sha(),
             subject: String.t()
           }}
          | git_error()
  def commit_info(repo, sha) do
    case run(repo, ["show", "-s", "--format=%H%x00%P%x00%T%x00%s", sha]) do
      {:ok, out} ->
        [commit, parents, tree, subject] = String.split(String.trim(out), "\0")
        parent_shas = parents |> String.split(" ") |> Enum.reject(&(&1 == ""))
        {:ok, %{sha: commit, parent_shas: parent_shas, tree_sha: tree, subject: subject}}

      error ->
        error
    end
  end

  @doc """
  Returns `true` when `sha` is a merge commit (more than one parent).
  """
  @spec merge_commit?(repo(), sha()) :: {:ok, boolean()} | git_error()
  def merge_commit?(repo, sha) do
    case commit_info(repo, sha) do
      {:ok, info} -> {:ok, length(info.parent_shas) > 1}
      error -> error
    end
  end

  @doc """
  Lists the paths changed by `sha` relative to its parent, sorted and
  rename-free, so the set is stable across clones and git versions.
  """
  @spec changed_paths(repo(), sha()) :: {:ok, [String.t()]} | git_error()
  def changed_paths(repo, sha) do
    case run(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "--no-renames", "--root", sha]) do
      {:ok, out} -> {:ok, out |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.sort()}
      error -> error
    end
  end

  @doc """
  Resolves the blob sha that `commit` holds at `path`.

  `{:ok, nil}` covers both a deletion and any git failure (missing path,
  unreadable object): callers only need the `{:ok, _}` shape.
  """
  @spec path_blob(repo(), sha(), String.t()) :: {:ok, sha() | nil}
  def path_blob(repo, commit, path) do
    case run(repo, ["rev-parse", "#{commit}:#{path}"]) do
      {:ok, blob} -> {:ok, blob}
      {:error, {:git_failed, _, _}} -> {:ok, nil}
    end
  end

  @doc """
  Computes the stable patch id of `sha` via `git patch-id --stable`.

  The input diff is produced with pinned diff configuration (see the module
  doc) so the id only depends on the patch content, never on local git
  settings, platform, or clone.
  """
  @spec stable_patch_id(repo(), sha()) :: {:ok, String.t()} | git_error()
  def stable_patch_id(repo, sha) do
    with {:ok, patch} <- run(repo, ["diff-tree", "-p", "--root", "--no-renames", sha]),
         {:ok, out} <- patch_id_from_text(repo, patch) do
      case String.split(out, " ", parts: 2) do
        [id | _] when byte_size(id) > 0 -> {:ok, id}
        _ -> {:error, {:git_failed, 1, "git patch-id produced no id for #{sha}"}}
      end
    end
  end

  @doc """
  Computes stable patch ids for a bounded newest-first window of non-merge
  commits reachable from `tip` — the containment scan used for transformed
  (cherry-picked) delivery shas and for supersession detection.

  Returns a list of `{patch_id, sha}` pairs, newest commit first. `limit`
  caps how much of history is scanned; scans are exact within that window.
  """
  @spec patch_id_scan(repo(), String.t(), pos_integer()) :: {:ok, [{String.t(), sha()}]} | git_error()
  def patch_id_scan(repo, tip, limit) do
    with {:ok, log} <-
           run(repo, [
             "log",
             "--no-merges",
             "--no-renames",
             "--decorate=no",
             "-p",
             "-n",
             Integer.to_string(limit),
             tip
           ]),
         {:ok, out} <- patch_id_from_text(repo, log) do
      pairs =
        out
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          [id, commit] = String.split(line, " ", parts: 2)
          {id, commit}
        end)

      {:ok, pairs}
    end
  end

  @doc """
  Three-state ancestry check following the `SymphonyElixir` lane-lease
  pattern: `{:ok, true}` / `{:ok, false}` / git failure.
  """
  @spec ancestor?(repo(), sha(), sha()) :: {:ok, boolean()} | git_error()
  def ancestor?(repo, ancestor, descendant) do
    case System.cmd(
           "git",
           ["-c", "safe.directory=#{repo}", "-C", repo, "merge-base", "--is-ancestor", ancestor, descendant],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, true}
      {_, 1} -> {:ok, false}
      {out, code} -> {:error, {:git_failed, code, trim(out)}}
    end
  end

  @doc """
  Counts commits in `from..to` (`0` when `from` and `to` are identical).
  """
  @spec count_commits(repo(), sha(), sha()) :: {:ok, non_neg_integer()} | git_error()
  def count_commits(repo, from, to) do
    case run(repo, ["rev-list", "--count", "#{from}..#{to}"]) do
      {:ok, out} -> {:ok, String.to_integer(String.trim(out))}
      error -> error
    end
  end

  @doc """
  Lists paths changed on the line between two commits (used for changed-path
  overlap evidence against a moved main).
  """
  @spec range_changed_paths(repo(), sha(), sha()) :: {:ok, [String.t()]} | git_error()
  def range_changed_paths(repo, from, to) do
    case run(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "--no-renames", from, to]) do
      {:ok, out} -> {:ok, out |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.sort()}
      error -> error
    end
  end

  # `git patch-id` reads only stdin (never the repository), so the patch text
  # is staged in a uniquely-named temp file and redirected in via the shell.
  # System.cmd has no stdin option, and the shell never sees a path argument:
  # the working directory is the temp file's own directory. The `after` block
  # is the cleanup guarantee: even a spawn that raises (missing shell, temp
  # dir gone between write and spawn) removes the staged file first, so no
  # exit path leaks a `symphony_patch_id_*` file into the system temp dir.
  defp patch_id_from_text(_repo, text) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "symphony_patch_id_#{:erlang.unique_integer([:positive])}")
    :ok = File.write!(path, text)

    result =
      try do
        run_patch_id(dir, Path.basename(path))
      after
        _ = File.rm(path)
      end

    case result do
      {out, 0} -> {:ok, trim(out)}
      {out, code} -> {:error, {:git_failed, code, trim(out)}}
    end
  end

  # Indirection seam so tests can exercise spawn and parse failures against
  # the guaranteed cleanup above without touching the real command.
  defp run_patch_id(dir, file) do
    case Application.get_env(:symphony_elixir, :patch_id_runner) do
      nil -> native_patch_id(dir, file)
      runner -> runner.(dir, file)
    end
  end

  defp native_patch_id(dir, file) do
    case :os.type() do
      {:win32, _} -> System.cmd("cmd", ["/c", "git patch-id --stable < #{file}"], cd: dir, stderr_to_stdout: true)
      _ -> System.cmd("sh", ["-c", "git patch-id --stable < \"$1\"", "sh", file], cd: dir, stderr_to_stdout: true)
    end
  end

  defp trim(out), do: String.trim_trailing(out, "\n")
end
