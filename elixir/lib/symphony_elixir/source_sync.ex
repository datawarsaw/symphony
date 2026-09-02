defmodule SymphonyElixir.SourceSync do
  @moduledoc """
  Safely synchronizes the source repository's default branch before task worktree creation.

  Only fast-forwards clean source repositories that are strictly behind origin.
  Fails closed on dirty tracked files, staged changes, unmerged index state, local ahead,
  or diverged branches. Never runs destructive git operations or deletes untracked files.
  """

  require Logger
  alias SymphonyElixir.RepositoryRouter.Route

  @type reason_code ::
          :current
          | :fast_forwarded
          | :dirty_tracked
          | :dirty_index
          | :unmerged
          | :local_ahead
          | :diverged
          | :remote_unavailable
          | :default_branch_missing
          | :fast_forward_failed
          | :head_verification_failed
          | :not_a_git_repository

  @type sync_result ::
          {:ok, :current | :fast_forwarded}
          | {:error, reason_code() | {reason_code(), term()}}

  @spec sync(Route.t() | Path.t(), keyword()) :: sync_result()
  def sync(route_or_path, opts \\ [])

  def sync(%Route{source_path: path, default_branch: branch, remote: remote}, opts) do
    sync_repo(path, branch, Keyword.put_new(opts, :expected_remote, remote))
  end

  def sync(source_path, opts) when is_binary(source_path) do
    default_branch = Keyword.get(opts, :default_branch, "main")
    sync_repo(source_path, default_branch, opts)
  end

  @spec reason_code_string(reason_code() | {reason_code(), term()}) :: String.t()
  def reason_code_string(:current), do: "CURRENT"
  def reason_code_string(:fast_forwarded), do: "FAST_FORWARDED"
  def reason_code_string(:dirty_tracked), do: "DIRTY_TRACKED"
  def reason_code_string(:dirty_index), do: "DIRTY_INDEX"
  def reason_code_string(:unmerged), do: "UNMERGED"
  def reason_code_string(:local_ahead), do: "LOCAL_AHEAD"
  def reason_code_string(:diverged), do: "DIVERGED"
  def reason_code_string(:remote_unavailable), do: "REMOTE_UNAVAILABLE"
  def reason_code_string(:default_branch_missing), do: "DEFAULT_BRANCH_MISSING"
  def reason_code_string(:fast_forward_failed), do: "FAST_FORWARD_FAILED"
  def reason_code_string(:head_verification_failed), do: "HEAD_VERIFICATION_FAILED"
  def reason_code_string(:not_a_git_repository), do: "NOT_A_GIT_REPOSITORY"
  def reason_code_string({reason, _details}) when is_atom(reason), do: reason_code_string(reason)
  def reason_code_string(other), do: other |> to_string() |> String.upcase()

  defp sync_repo(source_path, default_branch, opts) do
    expected_remote = Keyword.get(opts, :expected_remote)

    with :ok <- validate_git_repository(source_path),
         :ok <- validate_remote_origin(source_path, expected_remote),
         :ok <- check_clean_working_tree(source_path),
         :ok <- fetch_origin_and_verify_default_branch(source_path, default_branch),
         {:ok, sync_action} <- determine_and_apply_sync(source_path, default_branch) do
      {:ok, sync_action}
    end
  end

  defp validate_git_repository(source_path) do
    case git_cmd(source_path, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true\n"} -> :ok
      _ -> {:error, :not_a_git_repository}
    end
  end

  defp validate_remote_origin(_source_path, nil), do: :ok

  defp validate_remote_origin(source_path, expected_remote) when is_binary(expected_remote) do
    case git_cmd(source_path, ["remote", "get-url", "origin"]) do
      {:ok, origin_url} ->
        if String.trim(origin_url) == String.trim(expected_remote) do
          :ok
        else
          {:error, {:remote_unavailable, {:remote_mismatch, expected_remote, String.trim(origin_url)}}}
        end

      {:error, _reason} ->
        {:error, :remote_unavailable}
    end
  end

  defp check_clean_working_tree(source_path) do
    with :ok <- check_unmerged_entries(source_path),
         :ok <- check_staged_changes(source_path),
         :ok <- check_tracked_changes(source_path) do
      :ok
    end
  end

  defp check_tracked_changes(source_path) do
    case git_cmd(source_path, ["diff", "--quiet"]) do
      {:ok, _} -> :ok
      {:error, {_, 1}} -> {:error, :dirty_tracked}
      {:error, _reason} -> {:error, :dirty_tracked}
    end
  end

  defp check_staged_changes(source_path) do
    case git_cmd(source_path, ["diff", "--cached", "--quiet"]) do
      {:ok, _} -> :ok
      {:error, {_, 1}} -> {:error, :dirty_index}
      {:error, _reason} -> {:error, :dirty_index}
    end
  end

  defp check_unmerged_entries(source_path) do
    case git_cmd(source_path, ["ls-files", "--unmerged"]) do
      {:ok, ""} -> :ok
      {:ok, _unmerged_files} -> {:error, :unmerged}
      {:error, _reason} -> {:error, :unmerged}
    end
  end

  defp fetch_origin_and_verify_default_branch(source_path, default_branch) do
    case git_cmd(source_path, ["fetch", "--prune", "origin"]) do
      {:ok, _} ->
        case git_cmd(source_path, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/#{default_branch}"]) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :default_branch_missing}
        end

      {:error, _reason} ->
        {:error, :remote_unavailable}
    end
  end

  defp determine_and_apply_sync(source_path, default_branch) do
    remote_ref = "refs/remotes/origin/#{default_branch}"
    local_ref = "refs/heads/#{default_branch}"

    case git_cmd(source_path, ["show-ref", "--verify", "--quiet", local_ref]) do
      {:error, _} ->
        with {:ok, _} <- git_cmd(source_path, ["branch", default_branch, remote_ref]),
             :ok <- verify_head_matches_remote(source_path, default_branch, remote_ref) do
          {:ok, :fast_forwarded}
        else
          _ -> {:error, :head_verification_failed}
        end

      {:ok, _} ->
        with {:ok, local_sha} <- git_rev_parse(source_path, local_ref),
             {:ok, remote_sha} <- git_rev_parse(source_path, remote_ref) do
          if local_sha == remote_sha do
            with :ok <- verify_head_matches_remote_if_checked_out(source_path, default_branch, remote_sha) do
              {:ok, :current}
            end
          else
            case git_cmd(source_path, ["rev-list", "--left-right", "--count", "#{local_ref}...#{remote_ref}"]) do
              {:ok, count_output} ->
                case parse_ahead_behind(count_output) do
                  {0, behind} when behind > 0 ->
                    apply_fast_forward(source_path, default_branch, remote_ref, remote_sha)

                  {ahead, 0} when ahead > 0 ->
                    {:error, :local_ahead}

                  {ahead, behind} when ahead > 0 and behind > 0 ->
                    {:error, :diverged}

                  _ ->
                    {:error, :diverged}
                end

              {:error, _} ->
                {:error, :remote_unavailable}
            end
          end
        end
    end
  end

  defp parse_ahead_behind(output) do
    case String.split(String.trim(output), ~r/\s+/) do
      [ahead_str, behind_str] ->
        {String.to_integer(ahead_str), String.to_integer(behind_str)}

      _ ->
        {:error, :invalid_rev_list_output}
    end
  rescue
    _ -> {:error, :invalid_rev_list_output}
  end

  defp apply_fast_forward(source_path, default_branch, remote_ref, expected_remote_sha) do
    current_branch = current_branch_name(source_path)

    ff_result =
      if current_branch == default_branch do
        git_cmd(source_path, ["merge", "--ff-only", remote_ref])
      else
        git_cmd(source_path, ["fetch", "origin", "refs/heads/#{default_branch}:refs/heads/#{default_branch}"])
      end

    case ff_result do
      {:ok, _} ->
        with :ok <- verify_post_fast_forward(source_path, default_branch, expected_remote_sha) do
          {:ok, :fast_forwarded}
        end

      {:error, _reason} ->
        {:error, :fast_forward_failed}
    end
  end

  defp verify_post_fast_forward(source_path, default_branch, expected_remote_sha) do
    local_ref = "refs/heads/#{default_branch}"

    with {:ok, local_sha} <- git_rev_parse(source_path, local_ref),
         :ok <- if(local_sha == expected_remote_sha, do: :ok, else: {:error, :head_verification_failed}),
         :ok <- verify_head_matches_remote_if_checked_out(source_path, default_branch, expected_remote_sha) do
      :ok
    end
  end

  defp verify_head_matches_remote_if_checked_out(source_path, default_branch, expected_remote_sha) do
    current_branch = current_branch_name(source_path)

    if current_branch == default_branch do
      case git_rev_parse(source_path, "HEAD") do
        {:ok, ^expected_remote_sha} -> :ok
        _ -> {:error, :head_verification_failed}
      end
    else
      :ok
    end
  end

  defp verify_head_matches_remote(source_path, default_branch, remote_ref) do
    with {:ok, remote_sha} <- git_rev_parse(source_path, remote_ref) do
      verify_head_matches_remote_if_checked_out(source_path, default_branch, remote_sha)
    end
  end

  defp current_branch_name(source_path) do
    case git_cmd(source_path, ["branch", "--show-current"]) do
      {:ok, branch} -> String.trim(branch)
      _ -> ""
    end
  end

  defp git_rev_parse(source_path, ref) do
    case git_cmd(source_path, ["rev-parse", "--verify", ref]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_cmd(source_path, args) do
    case System.cmd("git", ["-c", "safe.directory=#{source_path}", "-C", source_path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {output, status}}
    end
  end
end
