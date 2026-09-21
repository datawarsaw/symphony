defmodule SymphonyElixir.Delivery.ArtifactManifest do
  @moduledoc """
  Freeze manifest: a plain JSON record of exactly what a delivery accepted.

  A manifest is a pure value derived from git objects at freeze time. The
  helper keeps no state anywhere else — re-running the preflight always
  recomputes everything from the repository and the manifest file supplied on
  the command line, so there is no hidden mutable baseline to go stale.

  Single-commit artifacts carry one `commits` entry. Cumulative artifacts
  (for example a feature commit accepted together with a remediation commit)
  carry the ordered chain plus a `cumulative` block; the artifact is always
  proven as a whole, never commit-by-commit in isolation.

  Schema (version 1):

      {
        "schema_version": 1,
        "generated_at": "2026-09-21T12:00:00Z",
        "repository": "<advisory origin/origin path at freeze time>",
        "artifact_kind": "single" | "cumulative",
        "commits": [
          {
            "candidate_sha": "...",
            "parent_sha": "..." | null,
            "commit_subject": "...",
            "tree_sha": "...",
            "changed_paths": ["lib/foo.ex"],
            "stable_patch_id": "...",
            "path_blobs": {"lib/foo.ex": "<blob sha>" | null}
          }
        ],
        "cumulative": {
          "feature_sha": "...",
          "remediation_sha": "...",
          "original_parent_sha": "...",
          "ordered_patch_ids": ["...", "..."]
        }
      }
  """

  alias SymphonyElixir.Delivery.Git

  @schema_version 1

  @type repo :: Git.repo()
  @type sha :: Git.sha()

  @type entry :: %__MODULE__.Entry{
          candidate_sha: sha(),
          parent_sha: sha() | nil,
          commit_subject: String.t(),
          tree_sha: sha(),
          changed_paths: [String.t()],
          stable_patch_id: String.t(),
          path_blobs: %{String.t() => sha() | nil}
        }

  @type cumulative :: %__MODULE__.Cumulative{
          feature_sha: sha(),
          remediation_sha: sha(),
          original_parent_sha: sha() | nil,
          ordered_patch_ids: [String.t()]
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          generated_at: String.t(),
          repository: String.t(),
          artifact_kind: :single | :cumulative,
          commits: [entry()],
          cumulative: cumulative() | nil
        }

  defstruct [:schema_version, :generated_at, :repository, :artifact_kind, :commits, :cumulative]

  defmodule Entry do
    @moduledoc false
    defstruct [:candidate_sha, :parent_sha, :commit_subject, :tree_sha, :changed_paths, :stable_patch_id, :path_blobs]
  end

  defmodule Cumulative do
    @moduledoc false
    defstruct [:feature_sha, :remediation_sha, :original_parent_sha, :ordered_patch_ids]
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Freezes an ordered list of accepted candidate shas into a manifest.

  `shas` must be a linear chain as accepted (feature first, remediation
  last). Merge commits, unknown shas, and broken chains are rejected: a
  manifest can only record what git can mechanically prove.
  """
  @spec build(repo(), [sha()], keyword()) :: {:ok, t()} | {:error, term()}
  def build(repo, shas, opts \\ []) when is_list(shas) and shas != [] do
    with {:ok, resolved} <- resolve_chain(repo, shas),
         {:ok, entries} <- freeze_entries(repo, resolved),
         :ok <- validate_chain(entries) do
      manifest = %__MODULE__{
        schema_version: @schema_version,
        generated_at: generated_at(),
        repository: Keyword.get(opts, :repository, repo),
        artifact_kind: if(length(entries) == 1, do: :single, else: :cumulative),
        commits: entries,
        cumulative: cumulative_block(entries)
      }

      {:ok, manifest}
    end
  end

  @doc """
  Encodes a manifest as pretty JSON.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = manifest) do
    %{
      "schema_version" => manifest.schema_version,
      "generated_at" => manifest.generated_at,
      "repository" => manifest.repository,
      "artifact_kind" => Atom.to_string(manifest.artifact_kind),
      "commits" => Enum.map(manifest.commits, &encode_entry/1),
      "cumulative" => encode_cumulative(manifest.cumulative)
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Decodes and validates manifest JSON.

  Rejects unknown schema versions and structurally broken manifests; content
  truthfulness (do the shas and patch ids still match reality?) is the job
  of `SymphonyElixir.Delivery.Proof.self_check/2`, not of decoding.
  """
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, data} <- Jason.decode(json),
         :ok <- validate_schema_version(data),
         :ok <- validate_commits(data) do
      {:ok, from_data(data)}
    end
  end

  @doc """
  Loads and decodes a manifest from a file path.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, json} <- File.read(path), do: decode(json)
  end

  @doc """
  Writes a manifest to `path` (used by the `freeze` subcommand `--out`).
  """
  @spec save(t(), String.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = manifest, path) do
    File.write(path, encode(manifest))
  end

  @doc """
  First commit of the artifact (the feature commit when cumulative).
  """
  @spec first_entry(t()) :: entry()
  def first_entry(%__MODULE__{commits: [first | _]}), do: first

  @doc """
  Last commit of the artifact (the remediation commit when cumulative).
  """
  @spec last_entry(t()) :: entry()
  def last_entry(%__MODULE__{commits: commits}), do: List.last(commits)

  @doc """
  Ordered stable patch ids of the whole artifact, first accepted first.
  """
  @spec ordered_patch_ids(t()) :: [String.t()]
  def ordered_patch_ids(%__MODULE__{commits: commits}) do
    Enum.map(commits, & &1.stable_patch_id)
  end

  @doc """
  Union of changed paths across the whole artifact, in artifact order.
  """
  @spec changed_paths(t()) :: [String.t()]
  def changed_paths(%__MODULE__{commits: commits}) do
    Enum.flat_map(commits, & &1.changed_paths)
  end

  defp resolve_chain(repo, shas) do
    shas
    |> Enum.reduce_while({:ok, []}, fn sha, {:ok, acc} ->
      case Git.resolve_commit(repo, sha) do
        {:ok, full} -> {:cont, {:ok, [full | acc]}}
        {:error, :not_a_commit} -> {:halt, {:error, {:not_a_commit, sha}}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_chain([_single]), do: :ok

  defp validate_chain(entries) do
    broken =
      entries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [parent, child] -> child.parent_sha != parent.candidate_sha end)

    case broken do
      nil -> :ok
      [parent, child] -> {:error, {:broken_chain, parent.candidate_sha, child.candidate_sha}}
    end
  end

  defp freeze_entries(repo, shas) do
    Enum.reduce_while(shas, {:ok, []}, fn sha, {:ok, acc} ->
      case freeze_entry(repo, sha) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp freeze_entry(repo, sha) do
    with {:ok, info} <- Git.commit_info(repo, sha),
         :ok <- reject_merge(info),
         {:ok, paths} <- Git.changed_paths(repo, sha),
         {:ok, patch_id} <- Git.stable_patch_id(repo, sha),
         {:ok, blobs} <- freeze_path_blobs(repo, sha, paths) do
      {:ok,
       %Entry{
         candidate_sha: info.sha,
         parent_sha: List.first(info.parent_shas),
         commit_subject: info.subject,
         tree_sha: info.tree_sha,
         changed_paths: paths,
         stable_patch_id: patch_id,
         path_blobs: blobs
       }}
    end
  end

  defp reject_merge(%{parent_shas: parents}) when length(parents) > 1,
    do: {:error, :merge_commit_rejected}

  defp reject_merge(_), do: :ok

  defp freeze_path_blobs(repo, sha, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, acc} ->
      case Git.path_blob(repo, sha, path) do
        {:ok, blob} -> {:cont, {:ok, Map.put(acc, path, blob)}}
      end
    end)
  end

  defp cumulative_block([_single]), do: nil

  defp cumulative_block(entries) do
    %Cumulative{
      feature_sha: List.first(entries).candidate_sha,
      remediation_sha: List.last(entries).candidate_sha,
      original_parent_sha: List.first(entries).parent_sha,
      ordered_patch_ids: Enum.map(entries, & &1.stable_patch_id)
    }
  end

  defp generated_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp encode_entry(entry) do
    %{
      "candidate_sha" => entry.candidate_sha,
      "parent_sha" => entry.parent_sha,
      "commit_subject" => entry.commit_subject,
      "tree_sha" => entry.tree_sha,
      "changed_paths" => entry.changed_paths,
      "stable_patch_id" => entry.stable_patch_id,
      "path_blobs" => entry.path_blobs
    }
  end

  defp encode_cumulative(nil), do: nil

  defp encode_cumulative(cumulative) do
    %{
      "feature_sha" => cumulative.feature_sha,
      "remediation_sha" => cumulative.remediation_sha,
      "original_parent_sha" => cumulative.original_parent_sha,
      "ordered_patch_ids" => cumulative.ordered_patch_ids
    }
  end

  defp validate_schema_version(%{"schema_version" => version}) when version == @schema_version, do: :ok

  defp validate_schema_version(%{"schema_version" => version}),
    do: {:error, {:unsupported_schema_version, version}}

  defp validate_schema_version(_), do: {:error, :missing_schema_version}

  defp validate_commits(%{"commits" => commits}) when is_list(commits) and commits != [] do
    if Enum.all?(commits, &valid_entry_map?/1), do: :ok, else: {:error, :malformed_commit_entry}
  end

  defp validate_commits(_), do: {:error, :missing_or_empty_commits}

  defp valid_entry_map?(%{
         "candidate_sha" => sha,
         "parent_sha" => parent,
         "commit_subject" => subject,
         "tree_sha" => tree,
         "changed_paths" => paths,
         "stable_patch_id" => patch_id,
         "path_blobs" => blobs
       })
       when is_binary(sha) and is_binary(subject) and is_binary(tree) and is_binary(patch_id) and
              is_list(paths) and (is_map(blobs) or is_nil(blobs)) do
    is_nil(parent) or is_binary(parent)
  end

  defp valid_entry_map?(_), do: false

  defp from_data(data) do
    entries = Enum.map(data["commits"], &entry_from_data/1)

    %__MODULE__{
      schema_version: data["schema_version"],
      generated_at: data["generated_at"],
      repository: data["repository"],
      artifact_kind: if(length(entries) == 1, do: :single, else: :cumulative),
      commits: entries,
      cumulative: cumulative_from_data(data["cumulative"], entries)
    }
  end

  defp entry_from_data(map) do
    %Entry{
      candidate_sha: map["candidate_sha"],
      parent_sha: map["parent_sha"],
      commit_subject: map["commit_subject"],
      tree_sha: map["tree_sha"],
      changed_paths: map["changed_paths"],
      stable_patch_id: map["stable_patch_id"],
      path_blobs: map["path_blobs"] || %{}
    }
  end

  defp cumulative_from_data(nil, [_single]), do: nil

  defp cumulative_from_data(map, entries) when is_map(map) do
    %Cumulative{
      feature_sha: map["feature_sha"] || List.first(entries).candidate_sha,
      remediation_sha: map["remediation_sha"] || List.last(entries).candidate_sha,
      original_parent_sha: map["original_parent_sha"] || List.first(entries).parent_sha,
      ordered_patch_ids: map["ordered_patch_ids"] || Enum.map(entries, & &1.stable_patch_id)
    }
  end

  defp cumulative_from_data(_, _), do: nil
end
