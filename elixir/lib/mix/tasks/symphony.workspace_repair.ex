defmodule Mix.Tasks.Symphony.WorkspaceRepair do
  use Mix.Task

  @shortdoc "Repair proven Git worktree residue (stale registration / branch) for one workspace"

  @moduledoc """
  Bounded operator repair for proven Git residue left by an interrupted or
  partial workspace lifecycle.

  Symphony cleanup removes only the workspace directory. When a dispatch crashes
  between `git worktree add --no-checkout` and its checkout, or a workspace
  directory is deleted while the source repository still holds its registration,
  later dispatches fail forever: the task branch already exists, or the branch is
  still registered to a stale worktree. This command repairs exactly that residue
  for exactly one issue. It never inspects other workspaces.

  Usage:

      mix symphony.workspace_repair MT-123 --source C:/path/to/repo
      mix symphony.workspace_repair MT-123 --target symphony-runtime
      mix symphony.workspace_repair MT-123 --source ... --branch symphony/MT-123

  The task branch defaults to `symphony/<identifier>`, the naming contract used
  by the configured `after_create` hook. Run from the directory whose WORKFLOW.md
  defines the workspace root (the same directory the orchestrator runs from).

  Safety contract:

    1. Resolves one explicit workspace from the issue identifier only.
    2. Inspects the source repository's worktree registration and branch state.
    3. Refuses when a live, structurally viable workspace exists.
    4. Refuses when evidence is ambiguous — for example a workspace directory
       that is broken in any way other than the conclusive interrupted-create
       signature (never checked out), or one that contains untracked content.
    5. Prunes stale registrations with `git worktree prune --verbose` (Git's own
       tooling; it removes only registrations whose worktree directories are
       provably gone and reports every removal) or, for the interrupted-create
       leftover, `git worktree remove --force` (removes that workspace's
       directory and registration in one supported step).
    6. Deletes the branch only when conclusively safe: no remaining worktree
       registration references it, `origin/<default_branch>` exists, and the
       branch is fully contained in `origin/<default_branch>` (no unique
       evidence). Otherwise the branch is preserved and the command fails.
    7. Reports every action, re-reads Git state afterwards, and exits non-zero
       when the intended repair did not occur.

  Local only: workspaces on SSH worker hosts are out of scope, matching the
  local-only reuse gate.

  Never deletes a branch merely because a workspace directory is absent, and
  never runs Git maintenance beyond the one targeted removal.
  """

  @switches [branch: :string, source: :string, target: :string, default_branch: :string, help: :boolean]
  @aliases [h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("symphony.workspace_repair: unrecognized arguments: #{inspect(invalid)}")

      length(argv) != 1 ->
        Mix.raise("symphony.workspace_repair: expected exactly one issue identifier, got: #{inspect(argv)}")

      true ->
        repair(String.trim(List.first(argv)), opts)
    end
  end

  defp repair(identifier, opts) do
    branch = opts[:branch] || "symphony/#{identifier}"
    default_branch = opts[:default_branch] || default_branch_from_config()
    source_path = Path.expand(resolve_source_path!(opts))
    {:ok, workspace_path} = SymphonyElixir.Workspace.workspace_path(identifier)

    report("repair issue=#{identifier} workspace=#{workspace_path} source=#{source_path} branch=#{branch} default_branch=#{default_branch}")

    unless git_repo?(source_path) do
      refuse("source path is not a Git repository: #{source_path}")
    end

    state = inspect_state(source_path, workspace_path, branch, default_branch)
    report_state(state)

    state = repair_workspace(source_path, workspace_path, state)
    state = repair_branch(source_path, branch, default_branch, state)

    verify_repair(source_path, workspace_path, branch, state)

    report("repair complete: #{Enum.join(Enum.reverse(state.log), "; ")}")
    :ok
  end

  # --- workspace directory / registration ----------------------------------

  # Decides what may happen to the workspace directory and its registration
  # before any mutation. Every refusal here leaves the Git state untouched.
  defp repair_workspace(source_path, workspace_path, state) do
    cond do
      not state.workspace_exists? ->
        prune_stale_registration(source_path, workspace_path, state)

      state.viability == :ok ->
        refuse("live valid workspace exists at #{workspace_path}; nothing to repair")

      match?({:never_checked_out, _}, state.viability) ->
        {:never_checked_out, status} = state.viability
        remove_interrupted_worktree(source_path, workspace_path, status, state)

      true ->
        reason = elem(state.viability, 0)

        refuse(
          "workspace #{workspace_path} exists but is not provably repairable " <>
            "(viability reason: #{inspect(reason)}); directory contents: #{describe_dir_contents(workspace_path)}; " <>
            "refusing to touch ambiguous evidence"
        )
    end
  end

  defp describe_dir_contents(workspace_path) do
    case File.ls(workspace_path) do
      {:ok, []} -> "none (empty directory)"
      {:ok, entries} -> Enum.join(Enum.sort(entries), ", ")
      {:error, reason} -> "unreadable: #{inspect(reason)}"
    end
  end

  defp prune_stale_registration(source_path, workspace_path, state) do
    case state.registration do
      nil ->
        report("no worktree registration for #{workspace_path}; nothing to prune")
        state

      entry ->
        unless entry.prunable? do
          refuse("worktree registration for #{workspace_path} is live; refusing to prune")
        end

        report("pruning stale worktree registration (#{entry.prunable_reason || "stale"})")
        run_git!(source_path, ["worktree", "prune", "--verbose"])

        case registration_after(source_path, workspace_path) do
          nil ->
            %{state | log: ["pruned stale registration" | state.log]}

          _entry ->
            Mix.raise("symphony.workspace_repair: registration for #{workspace_path} survived prune")
        end
    end
  end

  # The interrupted-create leftover is the one broken state this command may
  # remove: checkout never ran, so the worktree holds no tracked content and no
  # worker history. It must contain nothing but Git's staged-deletion view of
  # the never-materialized checkout — any untracked or modified content means
  # possible worker evidence and a refusal.
  defp remove_interrupted_worktree(source_path, workspace_path, status_output, state) do
    case interrupted_create_contents_safe?(status_output) do
      {:ok, summary} ->
        report("removing interrupted-create worktree (index empty, no recoverable content: #{summary})")
        run_git!(source_path, ["worktree", "remove", "--force", workspace_path])

        if File.exists?(workspace_path) do
          Mix.raise("symphony.workspace_repair: workspace directory #{workspace_path} survived worktree remove")
        end

        case registration_after(source_path, workspace_path) do
          nil ->
            %{state | log: ["removed interrupted-create worktree" | state.log]}

          _entry ->
            Mix.raise("symphony.workspace_repair: registration for #{workspace_path} survived worktree remove")
        end

      {:ambiguous, detail} ->
        refuse(
          "workspace #{workspace_path} was never checked out but holds unexpected content " <>
            "(#{detail}); refusing to destroy possible evidence"
        )
    end
  end

  # `git status --porcelain` of a never-checked-out worktree lists every HEAD
  # file as a staged deletion (`D `). Untracked (`??`) or unstaged markers mean
  # real content is present; anything else is evidence this is not the clean
  # interrupted-create signature.
  defp interrupted_create_contents_safe?(status_output) do
    lines = status_output |> String.split("\n", trim: true)

    unexpected = Enum.filter(lines, fn line -> not String.starts_with?(line, "D ") end)

    cond do
      Enum.any?(lines, &String.starts_with?(&1, "??")) ->
        {:ambiguous, "untracked files present"}

      unexpected != [] ->
        {:ambiguous, "unexpected status entries: #{inspect(Enum.take(unexpected, 3))}"}

      true ->
        {:ok, "#{length(lines)} staged deletions of never-checked-out files"}
    end
  end

  # --- branch ---------------------------------------------------------------

  defp repair_branch(source_path, branch, default_branch, state) do
    case state.branch_sha do
      nil ->
        report("branch #{branch} does not exist; nothing to delete")
        state

      sha ->
        delete_branch_safely(source_path, branch, default_branch, sha, state)
    end
  end

  defp delete_branch_safely(source_path, branch, default_branch, sha, state) do
    ref = "refs/heads/#{branch}"

    if live_registration_for_branch(source_path, ref) do
      refuse("branch #{branch} is checked out in a live worktree; refusing to delete")
    end

    base_ref = "refs/remotes/origin/#{default_branch}"

    case git(source_path, ["show-ref", "--verify", base_ref]) do
      {:ok, _} ->
        :base_exists

      {:error, _} ->
        refuse("cannot prove branch safety: #{base_ref} does not exist; branch #{branch} preserved (was #{short(sha)})")
    end

    case ancestry(source_path, sha, base_ref) do
      :contained ->
        :safe

      :unique_evidence ->
        Mix.raise(
          "symphony.workspace_repair: branch #{branch} (#{short(sha)}) holds commits not in #{base_ref}; " <>
            "unique evidence preserved, refusing to delete"
        )

      {:git_failed, code, output} ->
        Mix.raise("symphony.workspace_repair: merge-base check failed (#{code}): #{String.trim(output)}")
    end

    report("deleting branch #{branch} (#{short(sha)}): fully contained in #{base_ref}")
    run_git!(source_path, ["branch", "-D", branch])

    case git(source_path, ["show-ref", "--verify", ref]) do
      {:error, _} ->
        %{state | log: ["deleted branch #{branch} (was #{short(sha)})" | state.log]}

      {:ok, _remaining} ->
        Mix.raise("symphony.workspace_repair: branch #{branch} still exists after delete")
    end
  end

  # `merge-base --is-ancestor` uses exit codes as its answer: 0 contained,
  # 1 not contained, anything else a Git failure.
  defp ancestry(source_path, sha, base_ref) do
    {output, code} =
      System.cmd("git", ["-c", "safe.directory=#{source_path}", "-C", source_path, "merge-base", "--is-ancestor", sha, base_ref], stderr_to_stdout: true)

    cond do
      code == 0 -> :contained
      code == 1 -> :unique_evidence
      true -> {:git_failed, code, output}
    end
  end

  defp live_registration_for_branch(source_path, branch_ref) do
    {:ok, output} = git(source_path, ["worktree", "list", "--porcelain"])

    output
    |> String.split("\n", trim: true)
    |> Enum.any?(&(&1 == "branch #{branch_ref}"))
  end

  # --- final verification ---------------------------------------------------

  defp verify_repair(source_path, workspace_path, branch, state) do
    leftover_registration = registration_after(source_path, workspace_path)
    leftover_branch = branch_sha_after(source_path, branch)

    failures =
      []
      |> maybe_failure("registration for #{workspace_path} still present", leftover_registration != nil)
      |> maybe_failure("branch #{branch} still present", leftover_branch != nil)
      |> maybe_failure("workspace directory still present", state.workspace_existed_before_removal? and File.exists?(workspace_path))

    case failures do
      [] ->
        :ok

      failures ->
        Mix.raise("symphony.workspace_repair: intended repair did not fully occur: #{Enum.join(failures, "; ")}")
    end
  end

  defp maybe_failure(failures, _message, false), do: failures
  defp maybe_failure(failures, message, true), do: [message | failures]

  # --- inspection -----------------------------------------------------------

  defp inspect_state(source_path, workspace_path, branch, default_branch) do
    workspace_exists? = File.exists?(workspace_path)
    registration = registration_after(source_path, workspace_path)
    branch_sha = branch_sha_after(source_path, branch)
    viability = inspect_viability(workspace_exists?, workspace_path, source_path, default_branch)

    %{
      branch_sha: branch_sha,
      log: [],
      registration: registration,
      # The removal path must know whether the directory it is about to verify
      # gone was really the directory seen at inspection time.
      workspace_existed_before_removal?: workspace_exists?,
      viability: viability,
      workspace_exists?: workspace_exists?
    }
  end

  defp inspect_viability(false, _workspace_path, _source_path, _default_branch), do: :absent

  defp inspect_viability(true, workspace_path, _source_path, _default_branch) do
    case SymphonyElixir.Workspace.Viability.verify(workspace_path) do
      :ok ->
        :ok

      {:error, {:workspace_not_viable, _path, reason}} ->
        reason_status =
          case reason do
            :never_checked_out ->
              case git(workspace_path, ["status", "--porcelain"]) do
                {:ok, output} -> {:never_checked_out, output}
                {:error, output} -> {:never_checked_out_unreadable, output}
              end

            other ->
              {other, nil}
          end

        reason_status
    end
  end

  defp report_state(state) do
    registration_summary =
      case state.registration do
        nil -> "none"
        entry -> "registered (prunable=#{entry.prunable?}#{prunable_suffix(entry)})"
      end

    branch_summary =
      case state.branch_sha do
        nil -> "absent"
        sha -> "present #{short(sha)}"
      end

    viability_summary =
      case state.viability do
        :absent -> "workspace absent"
        :ok -> "viable"
        {:never_checked_out, _} -> "never_checked_out (interrupted create)"
        {reason, _} -> "not viable: #{inspect(reason)}"
      end

    report("observed state: workspace_exists=#{state.workspace_exists?} viability=#{viability_summary} registration=#{registration_summary} branch=#{branch_summary}")
  end

  defp prunable_suffix(%{prunable?: false}), do: ""
  defp prunable_suffix(%{prunable_reason: nil}), do: ""
  defp prunable_suffix(%{prunable_reason: reason}), do: " reason=#{reason}"

  defp registration_after(source_path, workspace_path) do
    case SymphonyElixir.Workspace.Viability.registration_entry(source_path, workspace_path) do
      {:ok, entry} -> entry
      {:error, _reason} -> nil
    end
  end

  defp branch_sha_after(source_path, branch) do
    case git(source_path, ["show-ref", "--verify", "refs/heads/#{branch}"]) do
      {:ok, output} ->
        output |> String.split() |> List.first()

      {:error, _} ->
        nil
    end
  end

  # --- helpers --------------------------------------------------------------

  defp resolve_source_path!(opts) do
    cond do
      source = opts[:source] ->
        source

      target = opts[:target] ->
        routing = SymphonyElixir.Config.settings!().routing
        targets = (routing && routing.targets) || %{}

        case Map.fetch(targets, target) do
          {:ok, config} when is_map(config) ->
            Map.get(config, "source_path") || Map.get(config, :source_path) ||
              Mix.raise("symphony.workspace_repair: routing target #{target} has no source_path")

          _ ->
            Mix.raise("symphony.workspace_repair: unknown routing target #{inspect(target)}")
        end

      true ->
        Mix.raise("symphony.workspace_repair: pass --source <repository path> or --target <routing target>")
    end
  end

  defp default_branch_from_config do
    routing = SymphonyElixir.Config.settings!().routing
    (routing && routing.default_branch) || "main"
  end

  defp git_repo?(source_path) do
    match?({:ok, _}, git(source_path, ["rev-parse", "--git-common-dir"]))
  end

  defp run_git!(source_path, args) do
    case git(source_path, args) do
      {:ok, output} ->
        Enum.each(String.split(String.trim(output), "\n", trim: true), &report("git: " <> &1))
        :ok

      {:error, output} ->
        Mix.raise("symphony.workspace_repair: git #{Enum.join(args, " ")} failed: #{String.trim(output)}")
    end
  end

  defp git(repo_path, args) do
    case System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end

  defp refuse(reason), do: Mix.raise("symphony.workspace_repair: refusing to repair — #{reason}")

  defp report(message), do: Mix.shell().info("symphony.workspace_repair: #{message}")

  defp short(sha) when is_binary(sha), do: binary_part(sha, 0, min(byte_size(sha), 12))
end
