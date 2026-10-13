defmodule SymphonyElixir.OpenCode.Config do
  @moduledoc """
  Generates the isolated OpenCode configuration for one launch.

  Every known tool is denied unless it is named in `allowed_tools`. Unknown
  tool names and unrestricted grants fail closed. The same document is written
  to the launch config directory and the isolated XDG config directory.

  The deny-by-default permission map carries one explicit entry per known tool
  and deliberately NO wildcard key: opencode 1.18.28 resolves a document that
  combines a `tools` object with a wildcard-denied `permission` map
  (`"*" => "deny"`) to a worker agent with every tool disabled — including the
  tools the same document enables and allows (PILOT-TOOL-CALL-INTEROP). The
  explicit per-tool entries keep the identical effective permission set while
  leaving the resolved worker agent able to call exactly the permitted tools.
  `verify_resolved_tools/2` is the bounded, fail-closed check that the
  installed CLI resolves a generated document that way.
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

      # No "*" base key: with opencode 1.18.28 the wildcard-denied permission
      # map combined with the tools map below disables every resolved tool.
      # Deny-by-default is carried entirely by the explicit per-tool entries.
      permissions =
        Enum.reduce(@known_tools, %{}, fn tool, acc ->
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

  @probe_timeout_ms 30_000

  # Ambient variables the config-resolution probe may inherit. Everything else
  # in the parent environment is deleted before the CLI runs, so ambient
  # OPENCODE_* overrides and provider credentials can never reach the probe
  # child. Mirrors the launch isolation allowlist in
  # SymphonyElixir.OpenCode.Environment (minus credential-bearing keys, which
  # a config-resolution probe never needs).
  @probe_inherited_keys [
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
    "DRIVERDATA"
  ]

  @doc """
  Fail-closed check that the installed OpenCode CLI resolves a generated
  configuration with exactly the intended tool enablement for the `build`
  agent.

  The document itself must already be the explicit wildcard-free shape
  `build/1` produces: a wildcard permission key (the PILOT-TOOL-CALL-INTEROP
  root cause) fails the check before any process runs. Otherwise the document
  is written into an isolated throwaway sandbox and `opencode debug agent
  build` runs there under the launch-style allowlisted environment — no
  credentials, no ambient `OPENCODE_*` overrides, no provider contact, no
  model call. The resolution is bounded by `:timeout_ms`
  (default #{@probe_timeout_ms}) and must satisfy:

  - every tool the document enables resolves enabled, unless the CLI does not
    resolve that tool name at all (an unresolvable tool cannot be called);
  - every tool the resolution enables is enabled in the document, or is
    `write` while `edit` is enabled (`write` is governed by the `edit`
    permission and has no entry of its own).

  Any non-zero exit, timeout, unparseable output, missing tools map, or
  mismatch is an error. Options: `:executable` (CLI path; resolved exactly
  like a launch when omitted) and `:timeout_ms`.
  """
  @spec verify_resolved_tools(map(), keyword()) :: :ok | {:error, term()}
  def verify_resolved_tools(config, opts \\ []) when is_map(config) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)

    with {:ok, expected} <- expected_enablement(config),
         {:ok, executable} <- SymphonyElixir.OpenCode.Adapter.resolve_executable(opts),
         {:ok, output} <- run_resolution_probe(config, executable, timeout_ms) do
      compare_resolution(output, expected)
    end
  end

  # The validated document must be the explicit, wildcard-free shape build/1
  # produces; anything else fails closed before the CLI is invoked.
  defp expected_enablement(config) do
    permission = Map.get(config, "permission")
    tools = Map.get(config, "tools")

    cond do
      not is_map(permission) or not is_map(tools) ->
        {:error, :invalid_generated_config}

      Enum.any?(Map.keys(permission) ++ Map.keys(tools), &unrestricted_name?/1) ->
        {:error, :wildcard_permission_forbidden}

      true ->
        allowed = for {name, true} <- tools, into: MapSet.new(), do: name
        {:ok, {allowed, MapSet.member?(allowed, "edit")}}
    end
  end

  defp run_resolution_probe(config, executable, timeout_ms) do
    sandbox =
      Path.join(System.tmp_dir!(), "opencode-config-resolve-#{System.unique_integer([:positive])}")

    config_dir = Path.join(sandbox, "config")
    home = Path.join(sandbox, "home")
    tmp = Path.join(sandbox, "tmp")

    for dir <- [
          config_dir,
          Path.join(home, "AppData/Roaming"),
          Path.join(home, "AppData/Local"),
          Path.join(sandbox, "xdg-data"),
          Path.join(sandbox, "xdg-cache"),
          Path.join(sandbox, "xdg-state"),
          tmp
        ] do
      File.mkdir_p!(dir)
    end

    File.write!(Path.join(config_dir, "opencode.json"), Jason.encode!(config))

    try do
      isolated = %{
        "HOME" => home,
        "USERPROFILE" => home,
        "APPDATA" => Path.join(home, "AppData/Roaming"),
        "LOCALAPPDATA" => Path.join(home, "AppData/Local"),
        "XDG_DATA_HOME" => Path.join(sandbox, "xdg-data"),
        "XDG_CACHE_HOME" => Path.join(sandbox, "xdg-cache"),
        "XDG_STATE_HOME" => Path.join(sandbox, "xdg-state"),
        "XDG_CONFIG_HOME" => config_dir,
        "TEMP" => tmp,
        "TMP" => tmp,
        "TMPDIR" => tmp,
        "OPENCODE_CONFIG_DIR" => config_dir,
        "OPENCODE_DISABLE_PROJECT_CONFIG" => "1",
        "OPENCODE_PURE" => "1",
        "OPENCODE_DISABLE_DEFAULT_PLUGINS" => "1",
        "OPENCODE_DISABLE_AUTOUPDATE" => "1"
      }

      probe_task =
        Task.async(fn ->
          System.cmd(executable, ["debug", "agent", "build"],
            cd: sandbox,
            env: probe_env(isolated),
            stderr_to_stdout: true
          )
        end)

      case Task.yield(probe_task, timeout_ms) || Task.shutdown(probe_task, :kill) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, exit_code}} -> {:error, {:resolution_probe_exit, exit_code, output_excerpt(output)}}
        _ -> {:error, {:resolution_probe_timeout, timeout_ms}}
      end
    after
      cleanup_sandbox(sandbox)
    end
  end

  # The CLI spawns a helper process that can briefly outlive System.cmd and
  # hold the sandbox; a bounded retry keeps the OS temp root clean without
  # ever blocking the caller meaningfully.
  defp cleanup_sandbox(sandbox) do
    Enum.reduce_while(1..3, :ok, fn attempt, :ok ->
      case File.rm_rf(sandbox) do
        {:ok, _} -> {:halt, :ok}
        _error when attempt == 3 -> {:halt, :ok}
        _error ->
          Process.sleep(200)
          {:cont, :ok}
      end
    end)
  end

  # `System.cmd` env format: binary keys with binary values, `nil` deletes an
  # inherited variable (unlike the raw Port env used for the worker launch).
  defp probe_env(isolated) do
    parent = Map.new(System.get_env(), fn {key, value} -> {String.downcase(key), {key, value}} end)

    inherited =
      for key <- @probe_inherited_keys,
          {original, value} <- [Map.get(parent, String.downcase(key))],
          is_binary(value) and value != "",
          into: %{} do
        {original, value}
      end

    values = Map.merge(inherited, isolated)

    denied =
      for {key, _value} <- System.get_env(), not Map.has_key?(values, key), uniq: true do
        {key, nil}
      end

    Map.to_list(values) ++ denied
  end

  defp compare_resolution(output, {allowed, edit_allowed?}) do
    with {:ok, resolved} <- decode_resolution(output) do
      enabled = for {name, true} <- resolved, name != "invalid", into: MapSet.new(), do: name

      # `write` has no permission entry of its own: the CLI enables it exactly
      # when `edit` is enabled and enforces it under the edit permission.
      permitted = if edit_allowed?, do: MapSet.put(allowed, "write"), else: allowed

      disabled_allowed =
        allowed |> Enum.filter(fn name -> Map.get(resolved, name) == false end) |> Enum.sort()

      unexpected_enabled = Enum.sort(MapSet.to_list(MapSet.difference(enabled, permitted)))

      cond do
        disabled_allowed != [] -> {:error, {:resolved_tools_disabled, disabled_allowed}}
        unexpected_enabled != [] -> {:error, {:resolved_tools_unexpected, unexpected_enabled}}
        true -> :ok
      end
    end
  end

  defp decode_resolution(output) do
    case Jason.decode(output) do
      {:ok, %{"tools" => tools}} when is_map(tools) ->
        {:ok, tools}

      {:ok, _} ->
        {:error, {:resolved_agent_missing_tools, output_excerpt(output)}}

      {:error, reason} ->
        {:error, {:resolution_output_unparseable, reason, output_excerpt(output)}}
    end
  end

  defp output_excerpt(output) do
    flat = String.replace(output, "\n", " ")

    if String.length(flat) > 200 do
      String.slice(flat, 0, 200) <> "..."
    else
      flat
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
