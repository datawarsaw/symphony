defmodule SymphonyElixir.Codex.LocalShellTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Codex.LocalShell

  defp options(valid, env \\ %{}, git \\ nil) do
    [
      os: {:win32, :nt},
      env: &Map.get(env, &1),
      find: fn
        "git" -> git
        _ -> nil
      end,
      probe: fn path -> if path in valid, do: :ok, else: {:error, :enoent} end
    ]
  end

  test "1. explicit valid shell override wins" do
    shell = "D:/custom/bin/bash.exe"
    assert {:ok, ^shell} = LocalShell.resolve(shell, options([shell]))
  end

  test "2. explicit invalid shell fails closed" do
    shell = "D:/missing/bash.exe"
    assert {:error, {:local_shell_unusable, ^shell, :enoent}} = LocalShell.resolve(shell, options([]))
  end

  test "3. PATH has WSL bash before Git Bash -> Git Bash selected" do
    git = "C:/Program Files/Git/bin/bash.exe"
    env = %{"PATH" => "C:\\Windows\\System32;C:\\Program Files\\Git\\bin"}
    assert {:ok, ^git} = LocalShell.resolve(nil, options([git], env))
  end

  test "4. standard Git Bash path discovered" do
    git = "C:/Program Files/Git/bin/bash.exe"
    assert {:ok, ^git} = LocalShell.resolve(nil, options([git], %{"ProgramFiles" => "C:\\Program Files"}))

    custom_git = "D:/tools/Git/bin/bash.exe"
    assert {:ok, ^custom_git} = LocalShell.resolve(nil, options([custom_git], %{}, "D:/tools/Git/cmd/git.exe"))
  end

  test "5. WSL launcher with no usable distro rejected" do
    wsl = "C:/Windows/System32/bash.exe"

    assert {:error, {:no_valid_local_shell, failures}} =
             LocalShell.resolve(nil, options([wsl], %{"PATH" => "C:\\Windows\\System32"}))

    assert Enum.any?(failures, fn {:local_shell_unusable, path, reason} ->
             path == wsl and reason == :wsl_launcher_excluded
           end)

    wsl_opts = [
      os: {:win32, :nt},
      probe: fn ^wsl ->
        {:error, {:shell_exit, 1, "Windows Subsystem for Linux has no installed distributions"}}
      end
    ]

    assert {:error, {:local_shell_unusable, ^wsl, {:shell_exit, 1, msg}}} =
             LocalShell.resolve(wsl, wsl_opts)

    assert msg =~ "no installed distributions"
  end

  test "6. only invalid candidates -> clear failure with diagnostics" do
    env = %{"PATH" => "C:\\Windows\\System32;D:\\invalid"}
    assert {:error, {:no_valid_local_shell, failures}} = LocalShell.resolve(nil, options([], env))
    assert is_list(failures) and failures != []

    assert Enum.any?(failures, fn {:local_shell_unusable, _, reason} ->
             reason == :wsl_launcher_excluded
           end)

    assert Enum.any?(failures, fn {:local_shell_unusable, _, reason} -> reason == :enoent end)

    formatted = LocalShell.format_error({:no_valid_local_shell, failures})
    assert formatted =~ "Windows shell resolution failed"
    assert formatted =~ "WSL launcher was found on PATH but excluded"
    assert formatted =~ "Candidates considered:"
  end

  test "7. verified PATH bash accepted if supported" do
    shell = "D:/msys64/usr/bin/bash.exe"
    env = %{"PATH" => "C:\\Windows\\System32;D:\\msys64\\usr\\bin"}
    assert {:ok, ^shell} = LocalShell.resolve(nil, options([shell], env))
  end

  test "8. Linux behavior unchanged" do
    assert {:ok, "/bin/bash"} =
             LocalShell.resolve(nil,
               os: {:unix, :linux},
               find: fn "bash" -> "/bin/bash" end,
               probe: fn _ -> flunk("unexpected probe") end
             )

    assert {:error, :bash_not_found} =
             LocalShell.resolve(nil, os: {:unix, :linux}, find: fn _ -> nil end)
  end

  test "9. macOS behavior unchanged" do
    assert {:ok, "/bin/bash"} =
             LocalShell.resolve(nil,
               os: {:unix, :darwin},
               find: fn "bash" -> "/bin/bash" end,
               probe: fn _ -> flunk("unexpected probe") end
             )

    assert {:error, :bash_not_found} =
             LocalShell.resolve(nil, os: {:unix, :darwin}, find: fn _ -> nil end)
  end

  test "real shell probe accepts Git Bash and diagnoses missing or broken executables" do
    case LocalShell.resolve(nil) do
      {:ok, shell} -> assert :ok = LocalShell.probe(shell)
      {:error, _} -> :ok
    end

    assert {:error, reason} = LocalShell.probe("C:/missing/symphony/bash.exe")
    assert reason in [:enoent, {:shell_start_failed, :enoent}] or match?({:shell_start_failed, _}, reason)
  end
end
