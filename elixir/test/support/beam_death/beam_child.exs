# M1-BEAM-T isolated BEAM child (test support only).
#
# This file is executed by a *separate OS BEAM* (plain `elixir`, never `mix`)
# with `ERL_LIBS` pointing at the build's `_build/test/lib`. It is driven by the
# bounded controller in `test/symphony_elixir/beam_death_recovery_test.exs`.
#
# It only ever mutates the isolated authority root passed through the
# environment; it never touches a production Symphony runtime or workspace.
#
# Phases (`SYMPHONY_BEAM_PHASE`):
#   launch  - record the durable launch marker for a contained mock worker,
#             start that worker through the production `jobrun` wrapper, then
#             publish identity + process evidence for the controller.
#   recover - after the launch BEAM is gone, re-read the *same* authority root
#             and recompute the fence verdict plus the reuse/cleanup gates; when
#             the fence allows it, perform an authorized continuation launch.
#
# The controller terminates the child BEAM; this script only arms a self-halt
# safety net so a leaked child cannot outlive the bounded test run.

defmodule BeamDeathChild do
  @moduledoc false

  def main do
    root = fetch!("SYMPHONY_BEAM_ROOT")
    workflow = fetch!("SYMPHONY_BEAM_WORKFLOW")
    issue_id = fetch!("SYMPHONY_BEAM_ISSUE_ID")
    attempt_id = System.get_env("SYMPHONY_BEAM_ATTEMPT_ID", "1")
    signal = fetch!("SYMPHONY_BEAM_SIGNAL")
    phase = fetch!("SYMPHONY_BEAM_PHASE")
    deadline_ms = String.to_integer(fetch!("SYMPHONY_BEAM_DEADLINE_MS"))
    pid_file = fetch!("SYMPHONY_BEAM_PID_FILE")

    # Publish this BEAM's own OS pid first: the controller can clean up a child
    # that never reaches its signal file (for example a failed boot).
    write_atomic(pid_file, System.pid())

    Application.load(:symphony_elixir)
    Application.put_env(:symphony_elixir, :workflow_file_path, workflow)

    # Safety net: a child left behind must not outlive the bounded test run.
    _ =
      spawn(fn ->
        Process.sleep(deadline_ms)
        System.halt(3)
      end)

    result =
      case phase do
        "launch" -> launch(root, issue_id, attempt_id)
        "recover" -> recover(root, issue_id, attempt_id)
        other -> %{"phase" => other, "error" => "unknown_phase"}
      end

    write_json(signal, result)
    IO.puts("PHASE_DONE #{phase}")
    Process.sleep(:infinity)
  end

  # -- launch ---------------------------------------------------------------

  defp launch(root, issue_id, attempt_id) do
    workspace = Path.join([root, "workspaces", issue_id])
    File.mkdir_p!(workspace)

    identity =
      SymphonyElixir.WorkerContainment.new_identity(
        issue_id: issue_id,
        attempt_id: attempt_id,
        workspace: workspace,
        worker_host: nil,
        authority_root: root
      )

    # Same order the production AppServer uses: the durable marker is written
    # BEFORE the worker port exists, so the launch is recoverable after a BEAM
    # restart.
    :ok =
      SymphonyElixir.LaunchMarker.record(identity,
        identifier: "M1-BEAM-T",
        attempt_id: attempt_id,
        root: root
      )

    marker_path = SymphonyElixir.LaunchMarker.marker_path(issue_id, root: root)

    scratch = fetch!("SYMPHONY_BEAM_SCRATCH_DIR")
    scratch_exe = fetch!("SYMPHONY_BEAM_SCRATCH_EXE")
    lifetime = fetch!("SYMPHONY_BEAM_LIFETIME_SEC")
    File.mkdir_p!(scratch)

    {:ok, jobrun} = SymphonyElixir.WorkerContainment.helper_path()

    scratch_args = [
      "--id",
      "beamworker",
      "--scratch",
      Path.join(scratch, "beamworker"),
      "--lifetime",
      lifetime,
      "--spawn-chain",
      "beamchild"
    ]

    args = SymphonyElixir.WorkerContainment.launch_args(identity, scratch_exe, scratch_args)

    port =
      Port.open({:spawn_executable, String.to_charlist(jobrun)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: String.to_charlist(workspace)
      ])

    %{
      "phase" => "launch",
      "authority_root" => root,
      "marker_root" => SymphonyElixir.LaunchMarker.root(root: root),
      "receipt_dir" => SymphonyElixir.WorkerContainment.receipt_dir(root),
      "marker_path" => marker_path,
      "marker_exists" => File.exists?(marker_path),
      "identity" => identity,
      "wrapper_pid" => os_pid(port),
      "beam_os_pid" => System.pid(),
      "workspace" => workspace,
      "scratch_dir" => scratch
    }
  end

  defp os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      {:os_pid, pid} when is_list(pid) -> List.to_integer(pid)
      _ -> nil
    end
  end

  # -- recover --------------------------------------------------------------

  defp recover(root, issue_id, attempt_id) do
    marker = read_marker(root, issue_id)
    identity = marker && Map.get(marker, "worker_identity")
    receipt = receipt(identity)

    evidence = %{
      "phase" => "recover",
      "beam_os_pid" => System.pid(),
      "authority_root" => root,
      "marker_root" => SymphonyElixir.LaunchMarker.root(root: root),
      "receipt_dir" => SymphonyElixir.WorkerContainment.receipt_dir(root),
      "marker_status" => marker_status(root, issue_id),
      "marker_launch_id" => marker && Map.get(marker, "launch_id"),
      "marker_workspace" => marker && Map.get(marker, "workspace"),
      "marker_identity_authority_root" => identity && Map.get(identity, "authority_root"),
      "receipt_path" => identity && Map.get(identity, "receipt_path"),
      "receipt" => receipt,
      "receipt_launch_id_matches" => receipt != nil and receipt["launch_id"] == (marker && marker["launch_id"]),
      "verdict" => verdict(issue_id, root),
      "identity_receipt_verdict" => identity_verdict(identity),
      "reuse_gate" => gate(SymphonyElixir.LaunchMarker.reuse_gate(issue_id, root: root)),
      "cleanup_gate" => gate(SymphonyElixir.LaunchMarker.cleanup_gate(issue_id, root: root))
    }

    Map.put(evidence, "continuation", continuation(evidence, root, issue_id, attempt_id))
  end

  defp read_marker(root, issue_id) do
    case SymphonyElixir.LaunchMarker.read(issue_id, root: root) do
      {:ok, marker} -> marker
      _ -> nil
    end
  end

  defp marker_status(root, issue_id) do
    case SymphonyElixir.LaunchMarker.read(issue_id, root: root) do
      {:ok, _marker} -> "VALID"
      {:error, reason} -> reason |> to_string() |> String.upcase()
    end
  end

  defp receipt(nil), do: nil

  defp receipt(identity) do
    case SymphonyElixir.WorkerContainment.parse_receipt(identity["receipt_path"]) do
      {:ok, receipt} -> receipt
      {:error, _reason} -> nil
    end
  end

  defp verdict(issue_id, root) do
    case SymphonyElixir.LaunchMarker.fence_verdict(issue_id, root: root) do
      {:ok, :dead} -> "DEAD"
      {:error, :alive} -> "ALIVE"
      {:error, :unknown} -> "UNKNOWN"
    end
  end

  defp identity_verdict(nil), do: "UNKNOWN"

  defp identity_verdict(identity) do
    case SymphonyElixir.WorkerContainment.verify_identity_receipt(identity) do
      {:ok, :dead} -> "DEAD"
      {:error, :alive} -> "ALIVE"
      {:error, :unknown} -> "UNKNOWN"
    end
  end

  defp gate(:allowed), do: "ALLOWED"
  defp gate({:blocked, reason}), do: "BLOCKED:" <> to_string(reason)

  # Authorized continuation: only when the fence positively proved death may the
  # runtime start a replacement worker on the same workspace. The replacement is
  # launched through the same production wrapper and then stopped cleanly, so its
  # own receipt must also prove TERMINATED_CONFIRMED before the marker is cleared
  # (mirroring the production AppServer stop path).
  defp continuation(%{"reuse_gate" => "ALLOWED", "marker_workspace" => workspace}, root, issue_id, attempt_id)
       when is_binary(workspace) do
    scratch = fetch!("SYMPHONY_BEAM_SCRATCH_DIR")
    scratch_exe = fetch!("SYMPHONY_BEAM_SCRATCH_EXE")
    lifetime = fetch!("SYMPHONY_BEAM_LIFETIME_SEC")
    File.mkdir_p!(scratch)

    identity =
      SymphonyElixir.WorkerContainment.new_identity(
        issue_id: issue_id,
        attempt_id: attempt_id,
        workspace: workspace,
        worker_host: nil,
        authority_root: root
      )

    :ok =
      SymphonyElixir.LaunchMarker.record(identity,
        identifier: "M1-BEAM-T",
        attempt_id: attempt_id,
        root: root
      )

    {:ok, jobrun} = SymphonyElixir.WorkerContainment.helper_path()

    scratch_args = [
      "--id",
      "beamworker2",
      "--scratch",
      Path.join(scratch, "beamworker2"),
      "--lifetime",
      lifetime
    ]

    args = SymphonyElixir.WorkerContainment.launch_args(identity, scratch_exe, scratch_args)

    port =
      Port.open({:spawn_executable, String.to_charlist(jobrun)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: String.to_charlist(workspace)
      ])

    wrapper_pid = os_pid(port)
    identity = Map.put(identity, "wrapper_pid", to_string(wrapper_pid))

    confirmation =
      SymphonyElixir.WorkerContainment.stop_and_confirm(
        port,
        identity,
        SymphonyElixir.WorkerContainment.grace_ms()
      )

    receipt =
      case SymphonyElixir.WorkerContainment.parse_receipt(identity["receipt_path"]) do
        {:ok, receipt} -> receipt
        {:error, _reason} -> nil
      end

    # The receipt is written just before the wrapper exits; wait for the wrapper
    # itself to be gone so the replacement launch leaves no process behind.
    wrapper_gone = await_os_pid_gone(wrapper_pid, 15_000)

    if confirmation.status == :TERMINATED_CONFIRMED do
      SymphonyElixir.LaunchMarker.clear(identity, root: root)
    end

    %{
      "performed" => true,
      "launch_id" => identity["launch_id"],
      "status" => to_string(confirmation.status),
      "receipt_launch_id" => receipt && receipt["launch_id"],
      "receipt_tree_drained" => receipt && receipt["tree_drained"],
      "receipt_terminal_reason" => receipt && receipt["terminal_reason"],
      "wrapper_after_stop" => if(wrapper_gone, do: "GONE", else: "ALIVE"),
      "marker_after_stop" => marker_status(root, issue_id)
    }
  end

  defp continuation(_evidence, _root, _issue_id, _attempt_id), do: %{"performed" => false}

  # -- plumbing -------------------------------------------------------------

  defp write_json(path, map) do
    write_atomic(path, Jason.encode!(map, pretty: true))
  end

  defp write_atomic(path, content) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  defp os_pid_alive?(pid) when is_integer(pid) do
    case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true) do
      {output, 0} -> Regex.match?(~r/"#{pid}"/, output)
      _other -> false
    end
  end

  defp await_os_pid_gone(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_os_pid_gone(pid, deadline)
  end

  defp do_await_os_pid_gone(pid, deadline) do
    cond do
      not os_pid_alive?(pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(100) && do_await_os_pid_gone(pid, deadline)
    end
  end

  defp fetch!(name), do: System.fetch_env!(name)
end

BeamDeathChild.main()
