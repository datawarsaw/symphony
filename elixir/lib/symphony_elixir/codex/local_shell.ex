defmodule SymphonyElixir.Codex.LocalShell do
  @moduledoc """
  Resolves and verifies the local worker shell without implicitly launching WSL.

  ## Usability Criteria
  A shell candidate is considered usable if:
  1. The executable exists on disk and can be spawned.
  2. Executing `-lc 'test -n "$BASH_VERSION" && printf symphony-shell-ready'` succeeds
     within the bounded probe timeout (default: 5,000 ms).
  3. The process exits with status 0.
  4. The probe output contains the `symphony-shell-ready` marker, confirming it is a
     functional POSIX-compatible Bash shell and not an unconfigured WSL stub or crashing wrapper.

  Known WSL launcher paths (such as `C:/Windows/System32/bash.exe`) exit immediately
  with an error when no WSL distribution is installed and are excluded from implicit candidate
  resolution.
  """

  @marker "symphony-shell-ready"
  @default_probe_timeout_ms 5_000

  @type failure_reason ::
          :enoent
          | :wsl_launcher_excluded
          | {:not_bash, String.t()}
          | {:shell_exit, integer(), String.t()}
          | {:shell_probe_timeout, String.t()}
          | {:shell_start_failed, term()}

  @type candidate_failure :: {:local_shell_unusable, String.t(), failure_reason()}

  @type resolution_error ::
          {:local_shell_unusable, String.t(), failure_reason()}
          | {:no_valid_local_shell, [candidate_failure()]}
          | :bash_not_found

  @spec resolve(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, resolution_error()}
  def resolve(override, opts \\ []) do
    os = Keyword.get(opts, :os, :os.type())
    find = Keyword.get(opts, :find, &System.find_executable/1)
    probe = Keyword.get(opts, :probe, &probe/1)
    env = Keyword.get(opts, :env, &System.get_env/1)

    cond do
      is_binary(override) and String.trim(override) != "" ->
        path = find.(override) || override
        verify(path, probe)

      match?({:win32, _}, os) ->
        resolve_windows(env, find, probe)

      true ->
        case find.("bash") do
          nil -> {:error, :bash_not_found}
          path -> {:ok, path}
        end
    end
  end

  defp resolve_windows(env, find, probe) do
    raw_candidates = candidates(env, find)

    raw_candidates
    |> Enum.reduce_while({:error, {:no_valid_local_shell, []}}, fn path, {:error, {:no_valid_local_shell, failures}} ->
      if wsl?(path) do
        {:cont, {:error, {:no_valid_local_shell, failures ++ [{:local_shell_unusable, path, :wsl_launcher_excluded}]}}}
      else
        case verify(path, probe) do
          {:ok, _} = result ->
            {:halt, result}

          {:error, {:local_shell_unusable, candidate_path, reason}} ->
            {:cont, {:error, {:no_valid_local_shell, failures ++ [{:local_shell_unusable, candidate_path, reason}]}}}
        end
      end
    end)
  end

  defp candidates(env, find) do
    roots = [
      env.("ProgramW6432"),
      env.("ProgramFiles"),
      env.("ProgramFiles(x86)"),
      "C:/Program Files",
      "C:/Program Files (x86)"
    ]

    standard =
      for root <- Enum.reject(roots, &is_nil/1),
          sub <- ["/Git/bin/bash.exe", "/Git/usr/bin/bash.exe"] do
        normalize(root) <> sub
      end

    git =
      case find.("git") do
        nil ->
          []

        path ->
          root = path |> normalize() |> Path.dirname() |> Path.dirname()
          [root <> "/bin/bash.exe", root <> "/usr/bin/bash.exe"]
      end

    path =
      (env.("PATH") || "")
      |> String.split(";", trim: true)
      |> Enum.map(fn p ->
        normalized = normalize(String.trim(p, "\""))

        if String.ends_with?(String.downcase(normalized), "/bash.exe") do
          normalized
        else
          normalized <> "/bash.exe"
        end
      end)

    Enum.uniq(standard ++ git ++ path)
  end

  defp normalize(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
  end

  @doc "Checks if the candidate path points to a known Windows WSL launcher."
  @spec wsl?(String.t()) :: boolean()
  def wsl?(path) do
    normalized = path |> normalize() |> String.downcase()
    String.contains?(normalized, ["/windows/system32/", "/windows/sysnative/", "/windowsapps/"])
  end

  defp verify(path, probe) do
    case probe.(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:local_shell_unusable, path, reason}}
    end
  end

  @doc "Probes an executable to confirm it is a functional POSIX-compatible Bash shell."
  @spec probe(String.t(), non_neg_integer()) :: :ok | {:error, failure_reason()}
  def probe(path, timeout_ms \\ @default_probe_timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", ~c"test -n \"$BASH_VERSION\" && printf symphony-shell-ready"]
        ]
      )

    await_probe(port, System.monotonic_time(:millisecond) + timeout_ms, "")
  rescue
    error in ErlangError ->
      {:error, error.original}

    error ->
      {:error, {:shell_start_failed, Exception.message(error)}}
  end

  defp await_probe(port, deadline, output) do
    if System.monotonic_time(:millisecond) >= deadline do
      Port.close(port)
      {:error, {:shell_probe_timeout, output}}
    else
      receive_probe(port, deadline, output)
    end
  end

  defp receive_probe(port, deadline, output) do
    receive do
      {^port, {:data, data}} ->
        await_probe(port, deadline, String.slice(output <> data, 0, 2_000))

      {^port, {:exit_status, 0}} ->
        if String.contains?(output, @marker) do
          :ok
        else
          {:error, {:not_bash, output}}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:shell_exit, status, output}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, {:shell_probe_timeout, output}}
    end
  end

  @doc "Formats a shell resolution failure for diagnostics."
  @spec format_error(resolution_error()) :: String.t()
  def format_error({:local_shell_unusable, path, reason}) do
    "Configured local shell #{path} is unusable: #{format_reason(reason)}"
  end

  def format_error({:no_valid_local_shell, failures}) do
    wsl_found =
      Enum.any?(failures, fn {:local_shell_unusable, _, reason} ->
        reason == :wsl_launcher_excluded
      end)

    lines =
      [
        "Windows shell resolution failed. No usable POSIX-compatible bash found.",
        if(wsl_found,
          do: "WSL launcher was found on PATH but excluded (not supported without explicit configuration and installed distribution).",
          else: nil
        ),
        "Candidates considered:",
        Enum.map(failures, fn {:local_shell_unusable, path, reason} ->
          "  - #{path}: #{format_reason(reason)}"
        end)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    lines
  end

  def format_error(:bash_not_found) do
    "bash executable not found on PATH"
  end

  def format_error(other) do
    inspect(other)
  end

  defp format_reason(:enoent), do: "executable not found on disk"
  defp format_reason(:wsl_launcher_excluded), do: "WSL launcher excluded"
  defp format_reason({:shell_exit, code, out}), do: "exited with code #{code}: #{String.trim(out)}"
  defp format_reason({:not_bash, out}), do: "not a valid bash executable: #{String.trim(out)}"
  defp format_reason({:shell_probe_timeout, _}), do: "probe timed out"
  defp format_reason({:shell_start_failed, msg}), do: "failed to start: #{msg}"
  defp format_reason(reason), do: inspect(reason)
end
