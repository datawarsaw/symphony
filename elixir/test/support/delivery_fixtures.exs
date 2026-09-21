defmodule SymphonyElixir.Test.DeliveryFixtures do
  @moduledoc """
  Builds throwaway local git repositories for delivery-integrity tests.

  No network, no GitHub: every repository is `git init`-ed under the system
  temp directory and removed with `cleanup/1` (usually via `on_exit`).
  """

  @spec init_repo() :: String.t()
  def init_repo do
    dir = Path.join(System.tmp_dir!(), "delivery_fixture_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-b", "main"])
    git!(dir, ["config", "user.email", "delivery-fixture@example.test"])
    git!(dir, ["config", "user.name", "Delivery Fixture"])
    git!(dir, ["config", "commit.gpgsign", "false"])
    dir
  end

  @type change :: {:write, String.t(), String.t()} | {:delete, String.t()}

  @spec commit_file(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def commit_file(repo, path, content, message) do
    commit_changes(repo, message, [{:write, path, content}])
  end

  @spec commit_changes(String.t(), String.t(), [change()]) :: String.t()
  def commit_changes(repo, message, changes) do
    Enum.each(changes, fn
      {:write, path, content} ->
        absolute = Path.join(repo, path)
        File.mkdir_p!(Path.dirname(absolute))
        File.write!(absolute, content)
        git!(repo, ["add", path])

      {:delete, path} ->
        File.rm(Path.join(repo, path))
        git!(repo, ["add", path])
    end)

    git!(repo, ["commit", "-m", message])
    head(repo)
  end

  @spec merge(String.t(), String.t()) :: String.t()
  def merge(repo, sha) do
    git!(repo, ["-c", "core.editor=true", "merge", "--no-edit", sha])
    head(repo)
  end

  @spec delete_file(String.t(), String.t(), String.t()) :: String.t()
  def delete_file(repo, path, message) do
    File.rm(Path.join(repo, path))
    git!(repo, ["add", path])
    git!(repo, ["commit", "-m", message])
    head(repo)
  end

  @spec head(String.t()) :: String.t()
  def head(repo), do: String.trim(git_out!(repo, ["rev-parse", "HEAD"]))

  @spec parent_of(String.t(), String.t()) :: String.t()
  def parent_of(repo, sha), do: String.trim(git_out!(repo, ["rev-parse", "#{sha}^"]))

  @spec cherry_pick(String.t(), String.t()) :: String.t()
  def cherry_pick(repo, sha) do
    git!(repo, ["-c", "core.editor=true", "cherry-pick", sha])
    head(repo)
  end

  @spec reset_hard(String.t(), String.t()) :: String.t()
  def reset_hard(repo, sha) do
    git!(repo, ["reset", "--hard", sha])
    head(repo)
  end

  @spec file_content(String.t(), String.t()) :: String.t()
  def file_content(repo, path) do
    case System.cmd("git", ["-c", "safe.directory=#{repo}", "-C", repo, "show", "HEAD:#{path}"], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  end

  @spec cleanup(String.t()) :: :ok
  def cleanup(repo) do
    _ = File.rm_rf(repo)
    :ok
  end

  defp git!(repo, args), do: _ = git_out!(repo, args)

  defp git_out!(repo, args) do
    case System.cmd("git", ["-c", "safe.directory=#{repo}", "-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "fixture git #{inspect(args)} failed (#{code}): #{out}"
    end
  end
end
