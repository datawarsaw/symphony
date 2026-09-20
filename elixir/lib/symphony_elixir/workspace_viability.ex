defmodule SymphonyElixir.Workspace.Viability do
  @moduledoc """
  Structural worktree viability probes for local Symphony workspaces.

  Repository identity (`Workspace.verify_workspace_git_identity/3`) proves that a
  workspace belongs to the expected repository, but not that the worktree is
  structurally usable. An interrupted `after_create` hook can leave a registered
  worktree whose checkout never ran: `.git` is valid, the common dir matches, and
  the workspace still contains no files. A crash or a plain directory deletion can
  leave the workspace gutted while the source repository keeps the registration.

  Viability is a necessary condition for resume, never a cleanliness gate. Dirty
  workspaces (modified tracked files, untracked worker files, staged changes) are
  expected and stay resumable: the probes only detect provably broken structure.

  Conclusive broken signals:

    * `HEAD` cannot be resolved — the gitdir is missing, the registration was
      pruned underneath the workspace, or the worktree metadata is damaged.
    * The index is empty while `HEAD` has tracked files — the `--no-checkout`
      worktree never reached its `git checkout` step (`:never_checked_out`).
    * The index is partially populated relative to `HEAD` — the checkout was
      interrupted midway (`:incomplete_index`). Symphony workers never write the
      index (Git is read-only for them), so only the creation hook populates it;
      sparse checkouts would violate this assumption but are not used.
    * `git status` fails — the index or worktree metadata is corrupt enough that
      even a read-only status cannot run (`:git_status_failed`).

  States that cannot be proven broken (for example an empty `HEAD` tree with an
  empty index) pass: this gate fails closed only on conclusive evidence.
  """

  alias SymphonyElixir.PathSafety

  @type reason ::
          :head_unresolvable
          | :index_unreadable
          | :head_tree_unreadable
          | :never_checked_out
          | :incomplete_index
          | :git_status_failed

  @type registration_entry :: %{
          required(:path) => String.t(),
          required(:branch) => String.t() | nil,
          required(:prunable?) => boolean(),
          required(:prunable_reason) => String.t() | nil
        }

  @doc """
  Proves the workspace is a structurally viable Git worktree.

  Returns `:ok` when the workspace can be resumed safely, or
  `{:error, {:workspace_not_viable, workspace, reason}}` with the conclusive
  evidence otherwise. The workspace must already exist; existence is the
  caller's classification decision.
  """
  @spec verify(Path.t()) :: :ok | {:error, {:workspace_not_viable, Path.t(), reason()}}
  def verify(workspace) when is_binary(workspace) do
    with :ok <- require_head(workspace),
         :ok <- require_checked_out_index(workspace) do
      require_status_readable(workspace)
    end
  end

  defp require_head(workspace) do
    case git(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      {:ok, _head} ->
        :ok

      {:error, _output} ->
        {:error, {:workspace_not_viable, workspace, :head_unresolvable}}
    end
  end

  defp require_checked_out_index(workspace) do
    with {:ok, index_entries} <- count_entries(workspace, ["ls-files", "-z"], :index_unreadable, workspace),
         {:ok, head_entries} <-
           count_entries(workspace, ["ls-tree", "-r", "--name-only", "-z", "HEAD"], :head_tree_unreadable, workspace) do
      cond do
        head_entries > 0 and index_entries == 0 ->
          {:error, {:workspace_not_viable, workspace, :never_checked_out}}

        index_entries > 0 and index_entries < head_entries ->
          {:error, {:workspace_not_viable, workspace, :incomplete_index}}

        true ->
          :ok
      end
    end
  end

  defp require_status_readable(workspace) do
    case git(workspace, ["status", "--porcelain"]) do
      {:ok, _output} ->
        :ok

      {:error, _output} ->
        {:error, {:workspace_not_viable, workspace, :git_status_failed}}
    end
  end

  defp count_entries(workspace, args, failure_reason, not_viable_path) do
    case git(workspace, args) do
      {:ok, output} ->
        {:ok, output |> String.split("\0", trim: true) |> length()}

      {:error, _output} ->
        {:error, {:workspace_not_viable, not_viable_path, failure_reason}}
    end
  end

  @doc """
  Reads the source repository's worktree registration for one workspace path.

  Returns `{:ok, nil}` when the workspace is not registered, or the matching
  porcelain entry with its `prunable` evidence. Git itself decides what is
  prunable; this module only reports it.
  """
  @spec registration_entry(Path.t(), Path.t()) ::
          {:ok, registration_entry() | nil} | {:error, term()}
  def registration_entry(source_path, workspace_path)
      when is_binary(source_path) and is_binary(workspace_path) do
    with {:ok, canonical_source} <- PathSafety.canonicalize(source_path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path),
         {:ok, output} <- git(canonical_source, ["worktree", "list", "--porcelain"]) do
      {:ok, find_registration(output, canonical_workspace)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_registration(output, workspace_path) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_registration_entry/1)
    |> Enum.find(fn entry ->
      entry != nil and normalize_git_dir(entry.path) == normalize_git_dir(workspace_path)
    end)
  end

  defp parse_registration_entry(entry_block) do
    lines = String.split(entry_block, "\n", trim: true)

    case Enum.find(lines, &String.starts_with?(&1, "worktree ")) do
      nil ->
        nil

      "worktree " <> path ->
        %{
          path: path,
          branch: registration_branch(lines),
          prunable?: Enum.any?(lines, &String.starts_with?(&1, "prunable")),
          prunable_reason: prunable_reason(lines)
        }
    end
  end

  defp registration_branch(lines) do
    case Enum.find(lines, &String.starts_with?(&1, "branch ")) do
      "branch " <> branch -> branch
      nil -> nil
    end
  end

  defp prunable_reason(lines) do
    case Enum.find(lines, &String.starts_with?(&1, "prunable ")) do
      "prunable " <> reason -> String.trim(reason)
      nil -> nil
    end
  end

  defp git(repo_path, args) do
    case System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end

  # Mirrors `Workspace.normalize_git_dir/1`: registration paths are compared as
  # canonical absolute paths, case-folded on Windows.
  defp normalize_git_dir(path) when is_binary(path) do
    case :os.type() do
      {:win32, _} -> path |> String.replace("\\", "/") |> String.downcase()
      _ -> path
    end
  end
end
