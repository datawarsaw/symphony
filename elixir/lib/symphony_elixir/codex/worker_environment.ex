defmodule SymphonyElixir.Codex.WorkerEnvironment do
  @moduledoc false

  # Windows local workers get absolute workspace-rooted BEAM/Mix paths before
  # Codex starts. Ambient absolute build, dependency, Hex/Mix home, native
  # artifact and temporary directories live outside the issue workspace and
  # either fail inside the workspace-write sandbox or write outside the
  # authorized workspace. Absolute values are used so dependency subprocesses
  # that change their working directory still resolve the same directories.

  alias SymphonyElixir.PathSafety

  @environment_directories [
    {"MIX_BUILD_PATH", ".mix_build"},
    {"MIX_DEPS_PATH", ".mix_deps"},
    {"HEX_HOME", ".hex"},
    {"MIX_HOME", ".mix"},
    {"ELIXIR_MAKE_CACHE_DIR", ".elixir_make"},
    {"REBAR_CACHE_DIR", ".rebar_cache"},
    {"REBAR_GLOBAL_CONFIG_DIR", ".rebar_config"},
    {"TMPDIR", ".tmp"},
    {"TEMP", ".tmp"},
    {"TMP", ".tmp"}
  ]

  @type failure :: {:workspace_beam_environment_failed, String.t(), Path.t(), term()}

  @spec prepare(Path.t()) :: {:ok, [{charlist(), charlist()}]} | {:error, failure()}
  def prepare(workspace), do: prepare(workspace, :os.type())

  @spec prepare(Path.t(), {atom(), atom()}) :: {:ok, [{charlist(), charlist()}]} | {:error, failure()}
  def prepare(_workspace, os_type) when os_type != {:win32, :nt}, do: {:ok, []}

  def prepare(workspace, {:win32, :nt}) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- canonical_workspace(workspace) do
      prepare_directories(canonical_workspace)
    end
  end

  def prepare(workspace, _os_type) do
    fail("workspace", inspect(workspace), :invalid_workspace)
  end

  defp canonical_workspace(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical_workspace) || fail("workspace", canonical_workspace, :not_a_directory) do
      {:ok, canonical_workspace}
    else
      {:error, {:path_canonicalize_failed, path, reason}} -> fail("workspace", path, reason)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_directories(workspace) do
    @environment_directories
    |> Enum.reduce_while({:ok, []}, &prepare_environment(&1, &2, workspace))
    |> reverse_environment()
  end

  defp prepare_environment({name, directory}, {:ok, environment}, workspace) do
    path = Path.join(workspace, directory)

    case prepare_directory(name, path, workspace) do
      :ok -> {:cont, {:ok, [{String.to_charlist(name), String.to_charlist(path)} | environment]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp prepare_directory(name, path, workspace) do
    with {:ok, canonical_path} <- canonical_path(name, path),
         :ok <- ensure_contained(name, canonical_path, workspace),
         :ok <- mkdir(name, canonical_path),
         {:ok, confirmed_path} <- canonical_path(name, path),
         :ok <- ensure_contained(name, confirmed_path, workspace),
         :ok <- ensure_directory(name, confirmed_path) do
      probe_writable(name, confirmed_path)
    end
  end

  defp ensure_directory(name, path) do
    if File.dir?(path), do: :ok, else: fail(name, path, :not_a_directory)
  end

  defp canonical_path(name, path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, {:path_canonicalize_failed, failed_path, reason}} ->
        fail(name, failed_path, reason)
    end
  end

  defp ensure_contained(name, path, workspace) do
    relative_path = Path.relative_to(path, workspace)

    if relative_path != "." and relative_path != path and not String.starts_with?(relative_path, "..") do
      :ok
    else
      fail(name, path, :outside_workspace)
    end
  end

  defp mkdir(name, path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> fail(name, path, reason)
    end
  end

  defp probe_writable(name, path) do
    probe_path = Path.join(path, ".symphony-write-probe-#{System.unique_integer([:positive])}")

    case File.open(probe_path, [:write, :exclusive]) do
      {:ok, device} -> write_and_remove_probe(device, probe_path, name, path)
      {:error, reason} -> fail(name, path, reason)
    end
  end

  defp write_and_remove_probe(device, probe_path, name, path) do
    result =
      try do
        :file.write(device, "probe")
      after
        File.close(device)
      end

    case result do
      :ok ->
        remove_probe(probe_path, name, path)

      {:error, reason} ->
        File.rm(probe_path)
        fail(name, path, reason)
    end
  end

  defp remove_probe(probe_path, name, path) do
    case File.rm(probe_path) do
      :ok -> :ok
      {:error, reason} -> fail(name, path, reason)
    end
  end

  defp reverse_environment({:ok, environment}), do: {:ok, Enum.reverse(environment)}
  defp reverse_environment(error), do: error

  defp fail(name, path, reason),
    do: {:error, {:workspace_beam_environment_failed, name, path, reason}}
end
