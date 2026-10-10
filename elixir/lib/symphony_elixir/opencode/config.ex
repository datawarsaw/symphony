defmodule SymphonyElixir.OpenCode.Config do
  @moduledoc """
  Generates the isolated OpenCode configuration for one launch.

  Every known tool is denied unless it is named in `allowed_tools`. Unknown
  tool names and unrestricted grants fail closed. The same document is written
  to the launch config directory and the isolated XDG config directory.
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

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, allowed_tools} <- normalize_allowed_tools(opts) do
      allowed = MapSet.new(allowed_tools)

      permissions =
        Enum.reduce(@known_tools, %{"*" => "deny"}, fn tool, acc ->
          action = if MapSet.member?(allowed, tool), do: "allow", else: "deny"
          Map.put(acc, tool, action)
        end)

      tools =
        Map.new(@known_tools, fn tool ->
          {tool, MapSet.member?(allowed, tool)}
        end)

      {:ok,
       %{
         "$schema" => @schema_url,
         "plugin" => [],
         "tools" => tools,
         "permission" => permissions
       }}
    end
  end

  @spec write_config(Path.t() | map(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write_config(target, opts \\ [])

  def write_config(target, opts) when is_map(target) do
    with {:ok, encoded} <- encode(opts) do
      config_dir = target.config
      global_dir = Path.join(target.xdg_config, "opencode")
      File.mkdir_p!(config_dir)
      File.mkdir_p!(global_dir)
      root = Path.join(config_dir, "opencode.json")
      global = Path.join(global_dir, "opencode.json")
      File.write!(root, encoded)
      File.write!(global, encoded)
      {:ok, root}
    end
  rescue
    error in File.Error -> {:error, {:config_write_failed, error}}
  end

  def write_config(config_dir, opts) when is_binary(config_dir) do
    with {:ok, encoded} <- encode(opts) do
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

  defp encode(opts) do
    case build(opts) do
      {:ok, config} -> {:ok, Jason.encode!(config, pretty: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_allowed_tools(opts) do
    allowed = Keyword.get(opts, :allowed_tools, [])
    unrestricted = Keyword.get(opts, :unrestricted_permissions, false)
    auto_approve = Keyword.get(opts, :auto_approve, false)

    cond do
      unrestricted == true or auto_approve == true ->
        {:error, :unrestricted_permissions_forbidden}

      not is_list(allowed) ->
        {:error, :invalid_allowed_tools}

      true ->
        normalized = Enum.map(allowed, &normalize_tool_name/1)

        cond do
          Enum.any?(normalized, &unrestricted_name?/1) ->
            {:error, :unrestricted_permissions_forbidden}

          unknown = Enum.reject(normalized, &(&1 in @known_tools)) ->
            if unknown == [] do
              {:ok, normalized}
            else
              {:error, {:unknown_tool_permission, unknown}}
            end
        end
    end
  end

  defp unrestricted_name?(name) do
    name in ["*", "all", "any", "auto", "auto_approve"]
  end

  defp normalize_tool_name(tool) when is_atom(tool), do: Atom.to_string(tool)
  defp normalize_tool_name(tool) when is_binary(tool), do: String.trim(tool)
  defp normalize_tool_name(other), do: to_string(other)
end
