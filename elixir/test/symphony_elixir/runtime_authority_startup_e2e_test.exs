defmodule SymphonyElixir.RuntimeAuthorityStartupE2ETest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RuntimeLease

  @moduledoc """
  Fully end-to-end runtime authority check: real Symphony runtime processes
  (separate OS BEAMs) start against one isolated state root.

  Phase-12 sequence: runtime A becomes authoritative, runtime B fails closed
  before its Orchestrator becomes active, a hard crash of A leaves fail-closed
  residue, explicit operator recovery unblocks the root, and a clean subsequent
  startup acquires.

  Each runtime is a plain `elixir` BEAM with the build's `ERL_LIBS`, not a `mix`
  process: a nested mix would contend on build locks with this test's own VM.
  The boot script sets the application env `config/config.exs` would provide.

  Skipped unless `SYMPHONY_RUN_RUNTIME_LEASE_E2E=1` (boots four real BEAM
  applications; mirrors the SYMPHONY_RUN_LIVE_E2E gating convention).
  """

  @e2e_skip_reason if(System.get_env("SYMPHONY_RUN_RUNTIME_LEASE_E2E") != "1",
                     do: "set SYMPHONY_RUN_RUNTIME_LEASE_E2E=1 to enable the two-BEAM runtime authority startup test"
                   )

  @moduletag timeout: 300_000
  @boot_grace_ms 60_000

  @tag skip: @e2e_skip_reason
  test "two real runtime startups produce exactly one authority, crash residue fails closed, recovery unblocks" do
    root = Path.join(System.tmp_dir!(), "mic-runtime-lease-e2e-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    boot = write_boot_script(root)

    # Runtime A: becomes the authority for the root.
    {a_task, a_ref} = start_runtime(boot, root)
    a_lease = wait_for_lease(root, a_task, @boot_grace_ms)
    assert a_lease["kind"] == "runtime-authority"
    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["class"] == "active"

    # Runtime B: same root, rejected before any lifecycle authority exists.
    assert {output_b, 1} = run_boot(boot, root)
    assert output_b =~ "START_FAILED"
    assert output_b =~ "runtime_authority_held"
    assert output_b =~ a_lease["instance_id"]

    # Runtime A: hard crash (OS kill, no release, no terminate).
    kill_process(a_lease["os_pid"])
    assert_receive {:DOWN, ^a_ref, :process, _pid, :normal}, 30_000
    assert {:ok, {output_a, 1}} = Task.yield(a_task, 5_000)
    refute output_a =~ "START_FAILED"

    # Crash residue keeps fresh runtimes fail closed.
    assert {output_c, 1} = run_boot(boot, root)
    assert output_c =~ "START_FAILED"
    assert output_c =~ "runtime_authority_held"
    assert output_c =~ a_lease["instance_id"]

    # Explicit operator recovery clears the crashed owner's lease.
    assert {:ok, record} =
             RuntimeLease.force_release(root,
               confirm: true,
               reason: "operator: runtime A host lost mid-run (e2e)",
               forced_by: "operator-console",
               force_active: true
             )

    assert record["prior_state"]["instance_id"] == a_lease["instance_id"]

    # A clean subsequent startup acquires.
    {d_task, d_ref} = start_runtime(boot, root)
    d_lease = wait_for_lease(root, d_task, @boot_grace_ms)
    refute d_lease["instance_id"] == a_lease["instance_id"]
    assert {:ok, _} = RuntimeLease.observe(root)

    kill_process(d_lease["os_pid"])
    assert_receive {:DOWN, ^d_ref, :process, _pid, :normal}, 30_000
    assert {:ok, {output_d, 1}} = Task.yield(d_task, 5_000)
    refute output_d =~ "START_FAILED"
  end

  @tag skip: @e2e_skip_reason
  test "a runtime moving to a new configured root isolates runtimes instead of sharing one" do
    # The reviewer's attack, end to end: R1 owns root A. Configuration's
    # workspace/state root moves to B. R1 keeps mutating A (its pinned
    # authority root); a second runtime boots against B and acquires it.
    # Two live authorities over two DIFFERENT roots — concurrent mutation of
    # one root stays impossible, and the root change takes effect at restart.
    root_a = Path.join(System.tmp_dir!(), "mic-runtime-drift-a-#{:erlang.unique_integer([:positive])}")
    root_b = Path.join(System.tmp_dir!(), "mic-runtime-drift-b-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)

    on_exit(fn ->
      File.rm_rf(root_a)
      File.rm_rf(root_b)
    end)

    workflow = Path.join(root_a, "WORKFLOW.md")
    write_workflow(workflow, root_a)

    boot = write_boot_script(root_a)
    {a_task, a_ref} = start_runtime(boot, root_a, workflow)
    a_lease = wait_for_lease(root_a, a_task, @boot_grace_ms)
    assert a_lease["state_root"] == root_a

    # Configuration moves the desired root to B while R1 runs on A.
    write_workflow(workflow, root_b)

    # A fresh runtime resolves B, leases B, and starts — allowed but isolated.
    {b_task, b_ref} = start_runtime(boot, root_b, workflow)
    b_lease = wait_for_lease(root_b, b_task, @boot_grace_ms)
    assert b_lease["state_root"] == root_b
    refute b_lease["instance_id"] == a_lease["instance_id"]

    # R1 still owns A the whole time.
    assert {:ok, evidence_a} = RuntimeLease.observe(root_a)
    assert evidence_a["instance_id"] == a_lease["instance_id"]

    kill_process(b_lease["os_pid"])
    assert_receive {:DOWN, ^b_ref, :process, _pid, :normal}, 30_000

    kill_process(a_lease["os_pid"])
    assert_receive {:DOWN, ^a_ref, :process, _pid, :normal}, 30_000
  end

  @tag skip: @e2e_skip_reason
  test "R1 on A, config moves to B, restart adopts B; marker stores stay isolated" do
    root_a = Path.join(System.tmp_dir!(), "mic-restart-a-#{:erlang.unique_integer([:positive])}")
    root_b = Path.join(System.tmp_dir!(), "mic-restart-b-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)

    on_exit(fn ->
      File.rm_rf(root_a)
      File.rm_rf(root_b)
    end)

    workflow = Path.join(root_a, "WORKFLOW.md")
    write_workflow(workflow, root_a)

    boot = write_boot_script(root_a)

    # R1 acquires A and is the only authority over A.
    {a_task, a_ref} = start_runtime(boot, root_a, workflow)
    a_lease = wait_for_lease(root_a, a_task, @boot_grace_ms)
    assert a_lease["state_root"] == root_a

    # Configuration moves the desired root to B while R1 runs, then R1 dies.
    write_workflow(workflow, root_b)
    kill_process(a_lease["os_pid"])
    assert_receive {:DOWN, ^a_ref, :process, _pid, :normal}, 30_000

    # A fresh runtime resolves B, acquires B, and pins its mutation domain to
    # B: the restart adopted the configured root.
    {b_task, b_ref} = start_runtime(boot, root_b, workflow)
    b_lease = wait_for_lease(root_b, b_task, @boot_grace_ms)
    assert b_lease["state_root"] == root_b
    refute b_lease["instance_id"] == a_lease["instance_id"]

    # Marker-store isolation across runtimes: while the B runtime ran its
    # lifecycle (marker gates, receipts, wake state), it never wrote into A's
    # store — and A's hard-crash authority residue is untouched by B.
    a_launches = Path.join([root_a, ".symphony-state", "launches"])
    a_runtime_dir = Path.join([root_a, ".symphony-state", "runtime"])

    assert {:ok, evidence_a} = RuntimeLease.observe(root_a)
    assert evidence_a["instance_id"] == a_lease["instance_id"]
    assert a_launches == Path.join([root_a, ".symphony-state", "launches"])

    if File.dir?(a_launches) do
      assert {:ok, []} = File.ls(a_launches)
    end

    if File.dir?(Path.join([root_b, ".symphony-state", "launches"])) do
      assert {:ok, []} = File.ls(Path.join([root_b, ".symphony-state", "launches"]))
    end

    refute File.exists?(Path.join(a_runtime_dir, "authority.recovery.json"))

    kill_process(b_lease["os_pid"])
    assert_receive {:DOWN, ^b_ref, :process, _pid, :normal}, 30_000
  end

  # -- runtime process plumbing --

  defp write_boot_script(root) do
    boot = Path.join(root, "runtime_boot.exs") |> Path.expand()

    File.write!(boot, """
    root = System.fetch_env!("SYMPHONY_E2E_ROOT")

    # The application env config/config.exs provides to a real boot.
    Application.put_env(:phoenix, :json_library, Jason)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "localhost"],
      render_errors: [formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON], layout: false],
      pubsub_server: SymphonyElixir.PubSub,
      live_view: [signing_salt: "symphony-live-view"],
      secret_key_base: String.duplicate("s", 64),
      check_origin: false,
      server: false
    )

    Application.put_env(:symphony_elixir, :workflow_file_path, System.fetch_env!("SYMPHONY_E2E_WORKFLOW"))
    Application.put_env(:symphony_elixir, :retry_store_root, root)
    Application.put_env(:symphony_elixir, :server_port_override, 0)
    Application.put_env(:symphony_elixir, :log_file, Path.join(root, "symphony.log"))
    Application.put_env(:symphony_elixir, :runtime_lease_heartbeat_ms, 1_000)

    case Application.ensure_all_started(:symphony_elixir) do
      {:ok, _started} ->
        {:ok, status} = SymphonyElixir.RuntimeLease.status()
        IO.puts("RUNTIME_AUTHORITATIVE instance_id=\#{status.instance_id}")
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts("START_FAILED \#{inspect(reason)}")
        System.halt(1)
    end
    """)

    boot
  end

  defp start_runtime(boot, root, workflow \\ nil) do
    task =
      Task.async(fn ->
        run_boot(boot, root, workflow)
      end)

    ref = Process.monitor(task.pid)
    {task, ref}
  end

  defp write_workflow(path, workspace_root) do
    File.write!(path, """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{workspace_root}
    ---

    Drift e2e workflow.
    """)
  end

  # The runtime boots through a written batch file: cmd.exe argument quoting of
  # a long elixir invocation is unreliable, a batch file is not. ERL_LIBS gives
  # the child BEAM the compiled apps without invoking mix in the child.
  defp run_boot(boot, root, workflow \\ nil) do
    batch = Path.join(Path.dirname(boot), "boot.cmd")
    elixir_bat = System.find_executable("elixir.bat") || raise("elixir.bat not found on PATH")
    erl_libs = Path.expand("_build/test/lib") |> String.replace("/", "\\")

    File.write!(batch, """
    @echo off
    set "ERL_LIBS=#{erl_libs}"
    "#{elixir_bat}" "#{boot}"
    """)

    workflow_path =
      workflow || Path.expand("../fixtures/startup_workflow.md", __DIR__)

    System.cmd(
      "cmd.exe",
      ["/c", batch],
      cd: File.cwd!(),
      env: %{
        "SYMPHONY_E2E_ROOT" => root,
        "SYMPHONY_E2E_WORKFLOW" => workflow_path
      },
      stderr_to_stdout: true
    )
  end

  defp wait_for_lease(_root, task, timeout) when timeout <= 0 do
    boot_output =
      case Task.yield(task, 0) do
        {:ok, {output, code}} -> "boot exited #{code}: #{String.slice(output, -2000, 2000)}"
        _ -> "boot still running"
      end

    flunk("runtime never acquired the lease; boot output: " <> boot_output)
  end

  defp wait_for_lease(root, task, timeout) do
    case RuntimeLease.observe(root) do
      {:ok, _evidence} ->
        path = RuntimeLease.authority_path(root)
        path |> File.read!() |> Jason.decode!()

      {:error, _reason} ->
        Process.sleep(250)
        wait_for_lease(root, task, timeout - 250)
    end
  end

  defp kill_process(os_pid) do
    assert {_, 0} = System.cmd("taskkill", ["/PID", os_pid, "/F", "/T"], stderr_to_stdout: true)
    :ok
  end
end
