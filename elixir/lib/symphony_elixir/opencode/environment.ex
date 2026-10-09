defmodule SymphonyElixir.OpenCode.Environment do
  @moduledoc """
  Manages isolated workspace state directories and scrubs credentials for OpenCode worker launches.

  Security invariants:
  - Global state isolation: OpenCode session, cache, state, and config directories are routed
    to a dedicated launch-specific subtree, never the user's global ~/.local or ~/.config dirs.
  - Deny-by-default credential boundary: tracker secrets (Linear, Jira, GitHub, GitLab, Asana,
    Stitch) and unrelated provider keys are scrubbed from the child environment.
  - Minimum necessary auth: only credentials strictly required for the selected provider
    are preserved.
  """

  alias SymphonyElixir.PathSafety

  @tracker_secrets [
    "LINEAR_API_KEY",
    "JIRA_API_TOKEN",
    "JIRA_PERSONAL_ACCESS_TOKEN",
    "JIRA_API_KEY",
    "JIRA_BEARER_TOKEN",
    "JIRA_EMAIL",
    "JIRA_BASE_URL",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITHUB_API_KEY",
    "GITHUB_PAT",
    "GITLAB_TOKEN",
    "GL_TOKEN",
    "GITLAB_API_KEY",
    "ASANA_ACCESS_TOKEN",
    "STITCH_API_KEY"
  ]

  @provider_credentials %{
    "anthropic" => ["ANTHROPIC_API_KEY"],
    "openai" => ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"],
    "google" => ["GOOGLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
    "xai" => ["XAI_API_KEY"],
    "groq" => ["GROQ_API_KEY"],
    "mistral" => ["MISTRAL_API_KEY"],
    "cohere" => ["COHERE_API_KEY"],
    "deepseek" => ["DEEPSEEK_API_KEY"],
    "openrouter" => ["OPENROUTER_API_KEY"],
    "azure" => ["AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT"],
    "aws" => ["AWS_SECRET_ACCESS_KEY", "AWS_ACCESS_KEY_ID", "AWS_SESSION_TOKEN"],
    "cloudflare" => ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"],
    "databricks" => ["DATABRICKS_TOKEN", "DATABRICKS_HOST"],
    "codex" => ["CODEX_API_KEY", "CODEX_SESSION_ID", "CODEX_THREAD_ID"]
  }

  @all_provider_secrets @provider_credentials |> Map.values() |> List.flatten() |> Enum.uniq()

  @type env_entry :: {charlist(), charlist() | false}

  @doc """
  Prepares isolated runtime directories for OpenCode under the specified workspace.
  Returns paths for data, cache, state, config, and tmp directories.
  """
  @spec prepare_directories(Path.t(), String.t()) ::
          {:ok, %{data: Path.t(), cache: Path.t(), state: Path.t(), config: Path.t(), tmp: Path.t(), root: Path.t()}}
          | {:error, term()}
  def prepare_directories(workspace, launch_id) when is_binary(workspace) and is_binary(launch_id) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical_workspace) || {:error, {:workspace_not_a_directory, canonical_workspace}} do
      state_root = Path.join([canonical_workspace, ".symphony-state", "opencode", launch_id])

      dirs = %{
        root: state_root,
        data: Path.join(state_root, "data"),
        cache: Path.join(state_root, "cache"),
        state: Path.join(state_root, "state"),
        config: Path.join(state_root, "config"),
        tmp: Path.join(state_root, "tmp")
      }

      with :ok <- ensure_contained(state_root, canonical_workspace),
           :ok <- File.mkdir_p(dirs.data),
           :ok <- File.mkdir_p(dirs.cache),
           :ok <- File.mkdir_p(dirs.state),
           :ok <- File.mkdir_p(dirs.config),
           :ok <- File.mkdir_p(dirs.tmp) do
        {:ok, dirs}
      else
        {:error, reason} -> {:error, {:environment_directory_failed, reason}}
      end
    end
  end

  @doc """
  Builds the complete scrubbed environment vector for a child OpenCode process.
  Preserves only the specified provider's authentication and injects isolated XDG directory paths.
  All unrelated tracker secrets and competitor provider keys are explicitly set to `false`
  (unsetting them in the spawned child process).
  """
  @spec build_port_env(String.t(), map(), keyword()) :: {:ok, [env_entry()]} | {:error, term()}
  def build_port_env(provider, dirs, opts \\ []) do
    preserved_keys = provider_auth_keys(provider, opts)
    caller_auth = Keyword.get(opts, :provider_auth, %{})

    # Collect all secrets that must be scrubbed:
    # 1. All tracker secrets
    # 2. All provider secrets for OTHER providers
    keys_to_scrub =
      (@tracker_secrets ++ (@all_provider_secrets -- preserved_keys))
      |> Enum.reject(&Map.has_key?(caller_auth, &1))
      |> Enum.uniq()

    # Base scrub directives: unset in child via {key, false}
    scrub_entries =
      Enum.map(keys_to_scrub, fn key ->
        {String.to_charlist(key), false}
      end)

    # Isolated directory directives
    dir_entries = [
      {~c"XDG_DATA_HOME", String.to_charlist(dirs.data)},
      {~c"XDG_CACHE_HOME", String.to_charlist(dirs.cache)},
      {~c"XDG_STATE_HOME", String.to_charlist(dirs.state)},
      {~c"XDG_CONFIG_HOME", String.to_charlist(dirs.config)},
      {~c"TEMP", String.to_charlist(dirs.tmp)},
      {~c"TMP", String.to_charlist(dirs.tmp)},
      {~c"TMPDIR", String.to_charlist(dirs.tmp)}
    ]

    # Explicit caller-supplied provider authentication (if any)
    auth_entries =
      Enum.map(caller_auth, fn {key, val} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(val))}
      end)

    # Provider keys inherited from ambient environment if not overridden
    ambient_auth_entries =
      preserved_keys
      |> Enum.reject(&Map.has_key?(caller_auth, &1))
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          val when is_binary(val) and val != "" ->
            [{String.to_charlist(key), String.to_charlist(val)}]

          _ ->
            []
        end
      end)

    {:ok, dir_entries ++ auth_entries ++ ambient_auth_entries ++ scrub_entries}
  end

  @doc """
  Returns the list of environment variable names to preserve for a given provider.
  """
  @spec provider_auth_keys(String.t(), keyword()) :: [String.t()]
  def provider_auth_keys(provider, opts \\ []) do
    normalized = provider |> to_string() |> String.downcase() |> String.trim()
    explicit = Keyword.get(opts, :preserve_auth_keys, [])
    standard = Map.get(@provider_credentials, normalized, [])
    Enum.uniq(standard ++ explicit)
  end

  @doc """
  Lists all tracker secrets that must be scrubbed across all runs.
  """
  @spec tracker_secrets() :: [String.t()]
  def tracker_secrets, do: @tracker_secrets

  @doc """
  Lists all provider secrets known to the system.
  """
  @spec all_provider_secrets() :: [String.t()]
  def all_provider_secrets, do: @all_provider_secrets

  defp ensure_contained(path, workspace) do
    rel = Path.relative_to(path, workspace)

    if rel != "." and rel != path and not String.starts_with?(rel, "..") do
      :ok
    else
      {:error, {:outside_workspace, path, workspace}}
    end
  end
end
