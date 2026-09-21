defmodule SymphonyElixir.RuntimeLeaseWindowsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeLease

  @moduledoc """
  Adversarial filesystem tests against real Windows semantics (no mocked
  filesystem behavior): an external OS process holds the authority file the way
  an antivirus scanner or backup tool would. Every lock mode is engaged before
  the assertions run, via a marker-file handshake.
  """

  @lock_hold_ms 4_000
  @marker_poll_attempts 150

  @windows_skip_reason if(match?({:win32, _}, :os.type()),
                         do: false,
                         else: "Windows-only filesystem adversarial tests"
                       )

  setup do
    root = Path.join(System.tmp_dir!(), "mic-runtime-lease-win-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp powershell_exe, do: System.find_executable("powershell.exe")

  # Spawns an external process holding `path` open with the given FileShare
  # (the AV/backup pattern) and runs `fun` once the lock is engaged.
  defp with_external_lock(path, share, fun) do
    marker = Path.join(Path.dirname(path), "lock-engaged-#{System.unique_integer([:positive])}.marker")
    script = Path.join(Path.dirname(path), "locker-#{System.unique_integer([:positive])}.ps1")
    win_path = String.replace(path, "/", "\\")
    win_marker = String.replace(marker, "/", "\\")

    File.write!(script, """
    $fs = [System.IO.File]::Open('#{win_path}', 'Open', 'ReadWrite', #{share})
    Set-Content -Path '#{win_marker}' -Value 'locked'
    Start-Sleep -Milliseconds #{@lock_hold_ms}
    $fs.Close()
    """)

    task =
      Task.async(fn ->
        System.cmd(powershell_exe(), ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script], stderr_to_stdout: true)
      end)

    wait_for_marker(marker, @marker_poll_attempts)
    result = fun.()
    Task.await(task, 30_000)
    _ = File.rm(script)
    _ = File.rm(marker)
    result
  end

  defp wait_for_marker(marker, 0), do: raise("marker never appeared: #{marker}")

  defp wait_for_marker(marker, attempts) do
    unless File.exists?(marker) do
      Process.sleep(50)
      wait_for_marker(marker, attempts - 1)
    end
  end

  # AV full deny: the authoritative file can be neither read nor removed. Every
  # operation fails closed and nothing — including operator recovery — reports
  # success while the lock is held.
  @tag skip: @windows_skip_reason
  test "an externally unreadable authority file fails every operation closed", %{root: root} do
    assert {:ok, lease} = RuntimeLease.claim(root)
    token = lease["owner_token"]
    path = RuntimeLease.authority_path(root)

    result =
      with_external_lock(path, "'None'", fn ->
        [
          claim: RuntimeLease.claim(root),
          observe: RuntimeLease.observe(root),
          renew: RuntimeLease.renew(root, token),
          release: RuntimeLease.release(root, token),
          force_release: RuntimeLease.force_release(root, confirm: true, reason: "operator: probe", force_active: true)
        ]
      end)

    assert {:error, {:lease_state_invalid, :unreadable_state}} = result[:claim]
    assert {:error, {:lease_state_invalid, :unreadable_state}} = result[:observe]
    assert {:error, {:lease_state_invalid, :unreadable_state}} = result[:renew]
    assert {:error, {:lease_state_invalid, :unreadable_state}} = result[:release]

    # recovery cannot even read the prior state for evidence: fail closed
    assert {:error, {:lease_state_invalid, :unreadable_state}} = result[:force_release]

    # nothing was mutated: the owner token survived untouched
    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["instance_id"] == lease["instance_id"]

    # after the external lock releases, the owner operates normally again
    assert {:ok, _} = RuntimeLease.renew(root, token)
    assert :ok = RuntimeLease.release(root, token)
  end

  # Partial lock (reads allowed, writes/deletes denied): the read path succeeds,
  # so renew reaches its temp+rename write and release reaches the removal —
  # both must report the filesystem failure instead of a false success.
  @tag skip: @windows_skip_reason
  test "an externally un-writable authority file fails writes and releases closed", %{root: root} do
    assert {:ok, lease} = RuntimeLease.claim(root)
    token = lease["owner_token"]
    path = RuntimeLease.authority_path(root)

    result =
      with_external_lock(path, "'Read'", fn ->
        [
          observe: RuntimeLease.observe(root),
          renew: RuntimeLease.renew(root, token),
          release: RuntimeLease.release(root, token)
        ]
      end)

    assert {:ok, _} = result[:observe]
    assert {:error, {:lease_write_failed, :eacces}} = result[:renew]
    assert {:error, {:lease_remove_failed, :eacces}} = result[:release]

    # the on-disk lease is unchanged: still owned, same token
    assert raw_lease(root)["owner_token"] == token

    # after the lock releases, the owner operates normally again
    assert {:ok, _} = RuntimeLease.renew(root, token)
    assert :ok = RuntimeLease.release(root, token)
  end

  defp raw_lease(root) do
    RuntimeLease.authority_path(root) |> File.read!() |> Jason.decode!()
  end
end
