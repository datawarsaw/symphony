defmodule SymphonyElixir.OpenCode.Config do
  @moduledoc """
  Generates isolated, secure OpenCode configuration with deny-by-default tool permissions.

  Security invariants:
  - Deny-by-default: tools are set to "deny" unless explicitly allowlisted.
  - Wildcard deny: "*" is explicitly set to "deny".
  - Unrestricted permissions forbidden: requests to allow "*", "all", or disable
    permission gates fail closed.
  - Plugin isolation: external plugins are disabled ("plugin": []).
  """

  @schema_url "https://opencode.ai/config.json"

  @known_tools [
    "read",
    "edit",
    "glob",
    "grep",
    "list",
    "bash",
    "task",
    "external_directory",
    "todowrite",
    "question",
    "webfetch",
    "websearch",
    "lsp",
    "doom_loop",
    "skill"
  ]

  @type permission_action :: :deny | :allow | :ask
  @type tool_name :: String.t() | atom()

  @doc """
  Builds a structured OpenCode configuration map with deny-by-default permissions.
  """
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    with :ok <- validate_permission_opts(opts) do
      allowed_tools =
        opts
        |> Keyword.get(:allowed_tools, [])
        |> Enum.map(&normalize_tool_name/1)
        |> MapSet.new()

      permissions =
        Enum.reduce(@known_tools, %{"*" => "deny"}, fn tool, acc ->
          action = if MapSet.member?(allowed_tools, tool), do: "allow", else: "deny"
          Map.put(acc, tool, action)
        end)

      config = %{
        "$schema" => @schema_url,
        "plugin" => [],
        "permission" => permissions
      }

      {:ok, config}
    end
  end

  @doc """
  Writes the generated OpenCode configuration to the target directory.
  Creates `opencode.json` both directly in the directory and in an `opencode/`
  subdirectory to ensure resolution across different OpenCode versions.
  """
  @spec write_config(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write_config(config_dir, opts \\ []) do
    with {:ok, config} <- build(opts) do
      encoded = Jason.encode!(config, pretty: true)
      opencode_sub = Path.join(config_dir, "opencode")

      File.mkdir_p!(opencode_sub)
      sub_file = Path.join(opencode_sub, "opencode.json")
      root_file = Path.join(config_dir, "opencode.json")

      File.write!(sub_file, encoded)
      File.write!(root_file, encoded)

      {:ok, sub_file}
    end
  rescue
    error in File.Error -> {:error, {:config_write_failed, error}}
  end

  defp validate_permission_opts(opts) do
    allowed = Keyword.get(opts, :allowed_tools, [])
    unrestricted = Keyword.get(opts, :unrestricted_permissions, false)
    auto_approve = Keyword.get(opts, :auto_approve, false)

    cond do
      unrestricted == true ->
        {:error, :unrestricted_permissions_forbidden}

      auto_approve == true ->
        {:error, :unrestricted_permissions_forbidden}

      is_list(allowed) and ("*" in allowed or :* in allowed or "all" in allowed or :all in allowed) ->
        {:error, :unrestricted_permissions_forbidden}

      not is_list(allowed) ->
        {:error, :invalid_allowed_tools}

      true ->
        :ok
    end
  end

  defp normalize_tool_name(tool) when is_atom(tool), do: Atom.to_string(tool)
  defp normalize_tool_name(tool) when is_binary(tool), do: String.trim(tool)
  defp normalize_tool_name(other), do: to_string(other)
end
