defmodule SymphonyElixir.OpenCode.Environment do
  @moduledoc """
  Builds an allowlisted child environment and an isolated configuration home
  for one OpenCode launch.

  The port environment replaces inherited variables instead of scrubbing a
  denylist. Only the selected provider's credentials may be present. OpenCode
  config, permission and home lookup variables are pinned to the launch
  directory so project files and the operator's global settings cannot widen
  permissions.

  Credential presence preflight: the same provider credential allowlist is the
  single mapping source for `preflight_provider_credentials/2`, which refuses
  a launch when the selected provider has no credential mapping, when no
  supported nonempty credential variable resolves for it, or when an
  endpoint/base-URL override would be inherited silently from the ambient
  environment instead of being supplied explicitly through `provider_auth`.
  The check verifies variable presence only — it never authenticates and
  never contacts a provider — and its error reasons carry provider and
  variable names, never credential values.
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
    "codex" => ["CODEX_API_KEY"],
    # Native OpenCode Go provider only; the separately billed "opencode" Zen
    # provider is deliberately unmapped, so its launches are refused.
    "opencode-go" => ["OPENCODE_API_KEY"]
  }

  @inherited_keys [
    "PATH",
    "PATHEXT",
    "SYSTEMROOT",
    "WINDIR",
    "COMSPEC",
    "SYSTEMDRIVE",
    "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE",
    "PROCESSOR_IDENTIFIER",
    "PROCESSOR_LEVEL",
    "PROCESSOR_REVISION",
    "OS",
    "USERNAME",
    "USERDOMAIN",
    "PROGRAMFILES",
    "PROGRAMFILES(X86)",
    "COMMONPROGRAMFILES",
    "DRIVERDATA",
    "OPENCODE_GIT_BASH_PATH"
  ]

  # Allowlist keys with these suffixes name where credentials are sent, not
  # the credentials themselves: they never satisfy credential presence, and
  # an ambient value for one is treated as an unauthorized redirect of the
  # selected provider's credentials.
  @endpoint_key_suffixes ["_BASE_URL", "_ENDPOINT", "_HOST"]

  @all_provider_secrets @provider_credentials |> Map.values() |> List.flatten() |> Enum.uniq()

  @type env_entry :: {charlist(), charlist() | false}
  @type dirs :: %{
          root: Path.t(),
          data: Path.t(),
          cache: Path.t(),
          state: Path.t(),
          config: Path.t(),
          tmp: Path.t(),
          home: Path.t(),
          managed: Path.t(),
          xdg_config: Path.t(),
          xdg_data: Path.t(),
          xdg_state: Path.t(),
          xdg_cache: Path.t()
        }

  @spec prepare_directories(Path.t(), String.t()) :: {:ok, dirs()} | {:error, term()}
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
        tmp: Path.join(state_root, "tmp"),
        home: Path.join(state_root, "home"),
        managed: Path.join(state_root, "managed"),
        xdg_config: Path.join(state_root, "xdg-config"),
        xdg_data: Path.join(state_root, "xdg-data"),
        xdg_state: Path.join(state_root, "xdg-state"),
        xdg_cache: Path.join(state_root, "xdg-cache")
      }

      created = [
        dirs.data,
        dirs.cache,
        dirs.state,
        dirs.config,
        dirs.tmp,
        dirs.home,
        Path.join(dirs.home, "AppData/Roaming"),
        Path.join(dirs.home, "AppData/Local"),
        dirs.managed,
        Path.join(dirs.xdg_config, "opencode"),
        dirs.xdg_data,
        dirs.xdg_state,
        dirs.xdg_cache
      ]

      with :ok <- ensure_contained(state_root, canonical_workspace),
           :ok <-
             Enum.reduce_while(created, :ok, fn dir, :ok ->
               case File.mkdir_p(dir) do
                 :ok -> {:cont, :ok}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
        {:ok, dirs}
      else
        {:error, reason} -> {:error, {:environment_directory_failed, reason}}
      end
    end
  end

  @spec build_port_env(String.t(), dirs(), keyword()) :: {:ok, [env_entry()]} | {:error, term()}
  def build_port_env(provider, dirs, opts \\ []) do
    with :ok <- preflight_provider_credentials(provider, opts),
         {:ok, allowed_keys} <- provider_auth_keys(provider, opts) do
      parent = System.get_env()
      parent_by_fold = fold_parent_env()

      inherited =
        Enum.reduce(@inherited_keys, %{}, fn key, acc ->
          case Map.get(parent_by_fold, String.downcase(key)) do
            {original, value} when is_binary(value) and value != "" ->
              Map.put(acc, original, value)

            _ ->
              acc
          end
        end)

      auth =
        for {key, value} <- resolve_auth_values(allowed_keys, opts),
            is_binary(value) and value != "",
            into: %{} do
          {env_key(parent_by_fold, key), value}
        end

      values =
        inherited
        |> Map.merge(isolated_values(dirs, parent_by_fold))
        |> Map.merge(auth)

      denied = denied_keys(parent, values)

      entries =
        Enum.map(values, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end) ++
          Enum.map(denied, fn key -> {String.to_charlist(key), false} end)

      {:ok, entries}
    end
  end

  @doc """
  Fail-closed credential presence preflight for an armed OpenCode launch.

  The provider credential allowlist that builds the child environment is the
  single mapping source: an unmapped provider identifier is refused instead of
  launching a child with an unknown credential contract. The launch is also
  refused when no supported nonempty credential variable resolves for the
  selected provider (caller `provider_auth` first, then the BEAM environment,
  exactly like `build_port_env/3`), and when an endpoint/base-URL override
  would be inherited silently from the ambient environment — a redirect the
  operator never authorized for this launch.

  Presence only: no authentication attempt, no provider contact. Error
  reasons carry provider and variable names, never credential values.
  """
  @spec preflight_provider_credentials(String.t(), keyword()) :: :ok | {:error, term()}
  def preflight_provider_credentials(provider, opts \\ []) do
    with {:ok, allowed_keys} <- provider_auth_keys(provider, opts),
         :ok <- ensure_credential_presence(provider, allowed_keys, opts),
         :ok <- reject_unexpected_endpoint_overrides(allowed_keys, opts) do
      :ok
    end
  end

  @spec provider_auth_keys(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def provider_auth_keys(provider, opts \\ []) do
    normalized = normalize_provider(provider)

    case Map.fetch(@provider_credentials, normalized) do
      :error -> {:error, {:unsupported_provider, normalized}}
      {:ok, allowed} -> authorize_requested_keys(allowed, opts)
    end
  end

  @spec tracker_secrets() :: [String.t()]
  def tracker_secrets, do: @tracker_secrets

  @spec all_provider_secrets() :: [String.t()]
  def all_provider_secrets, do: @all_provider_secrets

  @config_overrides [
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_CONTENT",
    "OPENCODE_PERMISSION",
    "OPENCODE_TUI_CONFIG",
    "OPENCODE_AUTH_CONTENT",
    "OPENCODE_API_KEY"
  ]

  defp isolated_values(dirs, parent_by_fold) do
    %{
      env_key(parent_by_fold, "HOME") => dirs.home,
      env_key(parent_by_fold, "USERPROFILE") => dirs.home,
      env_key(parent_by_fold, "APPDATA") => Path.join(dirs.home, "AppData/Roaming"),
      env_key(parent_by_fold, "LOCALAPPDATA") => Path.join(dirs.home, "AppData/Local"),
      env_key(parent_by_fold, "XDG_DATA_HOME") => dirs.xdg_data,
      env_key(parent_by_fold, "XDG_CACHE_HOME") => dirs.xdg_cache,
      env_key(parent_by_fold, "XDG_STATE_HOME") => dirs.xdg_state,
      env_key(parent_by_fold, "XDG_CONFIG_HOME") => dirs.xdg_config,
      env_key(parent_by_fold, "TEMP") => dirs.tmp,
      env_key(parent_by_fold, "TMP") => dirs.tmp,
      env_key(parent_by_fold, "TMPDIR") => dirs.tmp,
      env_key(parent_by_fold, "OPENCODE_CONFIG_DIR") => dirs.config,
      "OPENCODE_TEST_HOME" => dirs.home,
      "OPENCODE_TEST_MANAGED_CONFIG_DIR" => dirs.managed,
      "OPENCODE_DISABLE_PROJECT_CONFIG" => "1",
      "OPENCODE_PURE" => "1",
      "OPENCODE_DISABLE_DEFAULT_PLUGINS" => "1",
      "OPENCODE_DISABLE_EXTERNAL_SKILLS" => "1",
      "OPENCODE_DISABLE_CLAUDE_CODE" => "1",
      "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT" => "1",
      "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS" => "1",
      "OPENCODE_DISABLE_AUTOUPDATE" => "1"
    }
  end

  defp env_key(parent_by_fold, key) do
    case Map.get(parent_by_fold, String.downcase(key)) do
      {original, _} -> original
      _ -> key
    end
  end

  defp normalize_provider(provider), do: provider |> to_string() |> String.downcase() |> String.trim()

  defp fold_parent_env do
    Map.new(System.get_env(), fn {key, value} -> {String.downcase(key), {key, value}} end)
  end

  defp normalize_caller_auth(opts) do
    opts
    |> Keyword.get(:provider_auth, %{})
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  # Resolves each key the way build_port_env/3 hands it to the child: an
  # explicit nonempty caller value wins, otherwise a nonempty ambient BEAM
  # value (case-insensitively), otherwise nothing. Returns key -> value | nil.
  defp resolve_auth_values(keys, opts) do
    caller_auth = normalize_caller_auth(opts)
    parent_by_fold = fold_parent_env()
    Map.new(keys, fn key -> {key, resolved_key(caller_auth, parent_by_fold, key)} end)
  end

  defp resolved_key(caller_auth, parent_by_fold, key) do
    case caller_value(caller_auth, key) do
      nil -> ambient_value(parent_by_fold, key)
      value -> value
    end
  end

  defp caller_value(caller_auth, key) do
    case Map.get(caller_auth, key) do
      binary when is_binary(binary) and binary != "" -> binary
      _ -> nil
    end
  end

  defp ambient_value(parent_by_fold, key) do
    case Map.get(parent_by_fold, String.downcase(key)) do
      {_original, binary} when is_binary(binary) and binary != "" -> binary
      _ -> nil
    end
  end

  defp authorize_requested_keys(allowed, opts) do
    requested =
      (Keyword.get(opts, :preserve_auth_keys, []) ++
         (opts |> Keyword.get(:provider_auth, %{}) |> Map.keys()))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    case Enum.find(requested, &(&1 not in allowed)) do
      nil -> {:ok, allowed}
      key -> {:error, {:unauthorized_credential, key}}
    end
  end

  # Endpoint-shaped keys name a destination, not a credential: only the
  # remaining allowlist keys can satisfy presence.
  defp endpoint_key?(key), do: String.ends_with?(key, @endpoint_key_suffixes)

  defp ensure_credential_presence(provider, allowed_keys, opts) do
    credential_keys = Enum.reject(allowed_keys, &endpoint_key?/1)
    resolved = resolve_auth_values(credential_keys, opts)

    if Enum.any?(Map.values(resolved), &is_binary/1) do
      :ok
    else
      {:error, {:missing_provider_credential, normalize_provider(provider)}}
    end
  end

  # An endpoint override is expected only when the caller supplied it
  # explicitly through provider_auth for this launch. One that would instead
  # be inherited from the ambient BEAM environment redirects where the
  # selected provider's credentials are sent, so the launch is refused.
  defp reject_unexpected_endpoint_overrides(allowed_keys, opts) do
    caller_auth = normalize_caller_auth(opts)

    endpoint_keys = Enum.filter(allowed_keys, &endpoint_key?/1)
    resolved = resolve_auth_values(endpoint_keys, opts)

    unauthorized? = fn key ->
      is_binary(Map.get(resolved, key)) and is_nil(caller_value(caller_auth, key))
    end

    case Enum.find(endpoint_keys, unauthorized?) do
      nil -> :ok
      key -> {:error, {:unexpected_endpoint_override, key}}
    end
  end

  defp denied_keys(parent, values) do
    folds = MapSet.new(Map.keys(values), &String.downcase/1)

    forced = @tracker_secrets ++ @all_provider_secrets ++ @config_overrides

    parent_denied =
      Enum.reject(Map.keys(parent), fn key -> MapSet.member?(folds, String.downcase(key)) end)

    forced_denied =
      Enum.reject(forced, fn key -> MapSet.member?(folds, String.downcase(key)) end)

    Enum.uniq_by(parent_denied ++ forced_denied, &String.downcase/1)
  end

  defp ensure_contained(path, workspace) do
    rel = Path.relative_to(path, workspace)

    if rel != "." and rel != path and not String.starts_with?(rel, "..") do
      :ok
    else
      {:error, {:outside_workspace, path, workspace}}
    end
  end
end
