defmodule SymphonyElixir.RuntimeShutdownTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeLease
  alias SymphonyElixir.RuntimeShutdown

  setup do
    root = Path.join(System.tmp_dir!(), "mic-runtime-shutdown-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp foreign_instance_id, do: String.duplicate("f", 32)

  defp holder_opts(root, extra \\ []) do
    Keyword.merge(
      [
        name: Module.concat(__MODULE__, "Holder#{System.unique_integer([:positive])}"),
        root: root,
        runtime_supervisor: nil,
        heartbeat_ms: 3_600_000
      ],
      extra
    )
  end

  defp start_holder(root, extra \\ []) do
    opts = holder_opts(root, extra)
    # Temporary: a holder released via release_held/1 (a normal exit) must
    # stay dead — a permanent child would be restarted and re-adopt the lease.
    start_supervised!({RuntimeLease, opts}, restart: :temporary)
    opts[:name]
  end

  # A real supervised tree with one trivial child, standing in for the runtime
  # supervisor. Stopping it is a normal supervised termination.
  defp start_test_supervisor do
    name = Module.concat(__MODULE__, "Sup#{System.unique_integer([:positive])}")
    child = Module.concat(__MODULE__, "SupChild#{System.unique_integer([:positive])}")

    spec = %{
      id: name,
      start: {Supervisor, :start_link, [[{Task.Supervisor, name: child}], [name: name, strategy: :one_for_one]]},
      type: :supervisor
    }

    start_supervised!(spec, restart: :temporary)

    name
  end

  # The test stand-in for `Application.stop(:symphony_elixir)`: exactly the
  # production sequence — supervised tree termination first, then the
  # application stop callback's `release_held/1`.
  defp production_stop_sequence(supervisor, holder) do
    fn ->
      if Process.whereis(supervisor), do: GenServer.stop(supervisor, :normal, 5_000)
      RuntimeLease.release_held(holder)
      :ok
    end
  end

  defp write_lease_file(root, instance_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    lease = %{
      "schema_version" => 1,
      "kind" => "runtime-authority",
      "state_root" => root,
      "instance_id" => instance_id,
      "owner_token" => String.duplicate("a", 32),
      "os_pid" => "999999",
      "node" => "other@host",
      "hostname" => "other-host",
      "started_at" => now,
      "heartbeat_at" => now
    }

    File.mkdir_p!(RuntimeLease.authority_dir(root))
    File.write!(RuntimeLease.authority_path(root), Jason.encode!(lease, pretty: true))
    lease
  end

  defp write_foreign_lease(root), do: write_lease_file(root, foreign_instance_id())

  defp read_request_file(root), do: File.read(RuntimeShutdown.stop_request_path(root))

  defp drained_snapshot, do: fn -> %{running: []} end

  # -- guarded stop: authority preconditions --

  test "stop refuses with no holder and never touches a foreign lease", %{root: root} do
    foreign = write_foreign_lease(root)
    supervisor = start_test_supervisor()

    assert {:error, :no_runtime_authority} =
             RuntimeShutdown.stop(
               holder: Module.concat(__MODULE__, "Absent#{System.unique_integer([:positive])}"),
               supervisor: supervisor
             )

    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["instance_id"] == foreign["instance_id"]
  end

  test "stop refuses a successor's lease after the exact-ownership precondition fails", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    # A successor acquired the root out from under this instance (operator
    # recovery plus a fresh claim) while our holder is still alive.
    foreign = write_foreign_lease(root)

    assert {:error, :not_authority_holder} = RuntimeShutdown.stop(holder: holder, supervisor: supervisor)
    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["instance_id"] == foreign["instance_id"]
    assert Process.whereis(supervisor)
    assert RuntimeLease.authoritative?(holder)
  end

  test "check_ready passes for a live authoritative holder with a drained tree", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    assert :ok =
             RuntimeShutdown.check_ready(
               holder: holder,
               supervisor: supervisor,
               snapshot: drained_snapshot()
             )

    assert RuntimeLease.authoritative?(holder)
  end

  test "check_ready refuses while a worker is running", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    snapshot = fn -> %{running: [%{identifier: "MIC-1"}, %{identifier: "MIC-2"}]} end

    assert {:error, {:workers_still_running, ["MIC-1", "MIC-2"]}} =
             RuntimeShutdown.check_ready(holder: holder, supervisor: supervisor, snapshot: snapshot)

    assert {:ok, _} = RuntimeLease.observe(root)
  end

  test "check_ready refuses when the drain cannot be verified while the tree is up", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    assert {:error, {:drain_unverifiable, :orchestrator_unavailable}} =
             RuntimeShutdown.check_ready(holder: holder, supervisor: supervisor, snapshot: fn -> :unavailable end)

    assert {:error, {:drain_unverifiable, :orchestrator_timeout}} =
             RuntimeShutdown.check_ready(holder: holder, supervisor: supervisor, snapshot: fn -> :timeout end)

    assert {:ok, _} = RuntimeLease.observe(root)
  end

  # -- guarded stop: execution --

  test "graceful stop terminates the tree under supervision and releases the exact lease", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    assert :ok =
             RuntimeShutdown.stop(
               holder: holder,
               supervisor: supervisor,
               application_stop: production_stop_sequence(supervisor, holder)
             )

    assert {:error, :not_found} = RuntimeLease.observe(root)
    refute Process.whereis(holder)
    refute Process.whereis(supervisor)
  end

  test "graceful stop treats an already-dead tree as drained and still releases the lease", %{root: root} do
    holder = start_holder(root)

    assert :ok =
             RuntimeShutdown.stop(
               holder: holder,
               supervisor: Module.concat(__MODULE__, "NeverStarted#{System.unique_integer([:positive])}"),
               snapshot: fn -> :unavailable end,
               application_stop: fn ->
                 RuntimeLease.release_held(holder)
                 :ok
               end
             )

    assert {:error, :not_found} = RuntimeLease.observe(root)
  end

  test "graceful stop reports a lease that survived the stop instead of success", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    # The tree stops but the release never happens (a holder dead before the
    # stop callback, or recovery racing the stop): the residue is reported.
    assert {:error, {:lease_not_released, _evidence}} =
             RuntimeShutdown.stop(
               holder: holder,
               supervisor: supervisor,
               application_stop: fn ->
                 GenServer.stop(supervisor, :normal, 5_000)
                 :ok
               end
             )

    assert {:ok, _evidence} = RuntimeLease.observe(root)
    refute Process.whereis(supervisor)
  end

  # -- stop requests --

  test "request writes an attributable request naming the current lease holder", %{root: root} do
    holder = start_holder(root)
    {:ok, status} = RuntimeLease.status(holder)

    assert {:ok, body} =
             RuntimeShutdown.request(root, "operator: run complete", requested_by: "operator-console")

    assert body["instance_id"] == status.instance_id
    assert body["kind"] == "runtime-stop-request"
    assert body["requested_by"] == "operator-console"

    assert {:ok, raw} = read_request_file(root)
    assert {:ok, parsed} = RuntimeShutdown.parse_stop_request(raw, status.instance_id)
    assert parsed.reason == "operator: run complete"
  end

  test "request refuses without a lease and without attribution", %{root: root} do
    assert {:error, :no_runtime_lease} = RuntimeShutdown.request(root, "x", requested_by: "op")

    start_holder(root)

    assert {:error, :reason_required} = RuntimeShutdown.request(root, "  ", requested_by: "op")
    assert {:error, :requested_by_required} = RuntimeShutdown.request(root, "x", requested_by: "  ")
    refute File.exists?(RuntimeShutdown.stop_request_path(root))
  end

  test "request surfaces a conflicting pending request instead of replacing it", %{root: root} do
    start_holder(root)

    stale_request = %{
      "schema_version" => 1,
      "kind" => "runtime-stop-request",
      "instance_id" => foreign_instance_id(),
      "reason" => "older runtime",
      "requested_by" => "operator-console",
      "requested_at" => "2026-10-13T12:00:00Z"
    }

    File.mkdir_p!(RuntimeLease.authority_dir(root))
    stale_raw = Jason.encode!(stale_request, pretty: true)
    File.write!(RuntimeShutdown.stop_request_path(root), stale_raw)

    foreign_id = foreign_instance_id()

    assert {:error, {:stale_stop_request_present, %{path: path, instance_id: ^foreign_id}}} =
             RuntimeShutdown.request(root, "x", requested_by: "op")

    assert path == RuntimeShutdown.stop_request_path(root)
    assert {:ok, ^stale_raw} = read_request_file(root)
  end

  test "request rewrites a same-instance request in place", %{root: root} do
    holder = start_holder(root)
    {:ok, %{instance_id: instance_id}} = RuntimeLease.status(holder)

    assert {:ok, first} = RuntimeShutdown.request(root, "first", requested_by: "op")
    assert {:ok, second} = RuntimeShutdown.request(root, "second", requested_by: "op")
    assert first["reason"] == "first"
    assert second["reason"] == "second"

    assert {:ok, raw} = read_request_file(root)
    assert {:ok, parsed} = RuntimeShutdown.parse_stop_request(raw, instance_id)
    assert parsed.reason == "second"
  end

  test "parse_stop_request accepts only a valid exact-instance request" do
    body = %{
      "schema_version" => 1,
      "kind" => "runtime-stop-request",
      "instance_id" => String.duplicate("a", 32),
      "reason" => "done",
      "requested_by" => "op",
      "requested_at" => "2026-10-13T12:00:00Z"
    }

    raw = Jason.encode!(body)
    expected = body["instance_id"]

    assert {:ok, parsed} = RuntimeShutdown.parse_stop_request(raw, expected)
    assert parsed.instance_id == expected
    assert parsed.reason == "done"
    assert parsed.requested_by == "op"

    assert {:error, {:invalid_stop_request, :corrupt_json}} = RuntimeShutdown.parse_stop_request("{oops", expected)

    assert {:error, {:invalid_stop_request, :unknown_kind}} =
             RuntimeShutdown.parse_stop_request(Jason.encode!(%{body | "kind" => "other"}), expected)

    assert {:error, {:invalid_stop_request, :schema_version_invalid}} =
             RuntimeShutdown.parse_stop_request(Jason.encode!(%{body | "schema_version" => 2}), expected)

    assert {:error, {:invalid_stop_request, :instance_id_missing}} =
             RuntimeShutdown.parse_stop_request(Jason.encode!(%{body | "instance_id" => ""}), expected)

    assert {:error, {:invalid_stop_request, :instance_mismatch}} =
             RuntimeShutdown.parse_stop_request(raw, String.duplicate("b", 32))

    assert {:error, {:invalid_stop_request, :reason_required}} =
             RuntimeShutdown.parse_stop_request(Jason.encode!(%{body | "reason" => " "}), expected)

    assert {:error, {:invalid_stop_request, :requested_by_required}} =
             RuntimeShutdown.parse_stop_request(Jason.encode!(%{body | "requested_by" => ""}), expected)
  end

  # -- foreground wait loop --

  test "wait_for_shutdown returns :ok when the supervisor exits normally on its own" do
    supervisor = start_test_supervisor()
    task = Task.async(fn -> RuntimeShutdown.wait_for_shutdown(supervisor: supervisor, poll_ms: 20) end)

    GenServer.stop(supervisor, :normal)

    assert :ok = Task.await(task, 5_000)
  end

  test "wait_for_shutdown treats an application-master-style :shutdown exit as clean" do
    supervisor = start_test_supervisor()
    task = Task.async(fn -> RuntimeShutdown.wait_for_shutdown(supervisor: supervisor, poll_ms: 20) end)

    Process.sleep(50)
    :ok = GenServer.stop(supervisor, :shutdown)

    assert :ok = Task.await(task, 5_000)
  end

  test "wait_for_shutdown reports an abnormal supervisor exit" do
    supervisor = start_test_supervisor()
    task = Task.async(fn -> RuntimeShutdown.wait_for_shutdown(supervisor: supervisor, poll_ms: 20) end)

    # Let the waiter register its monitor before the kill, or the monitor
    # fires :noproc for the already-dead pid instead of the kill reason.
    Process.sleep(50)
    Process.exit(Process.whereis(supervisor), :kill)

    assert {:error, {:supervisor_exited, :killed}} = Task.await(task, 5_000)
  end

  test "wait_for_shutdown refuses when there is nothing to wait for" do
    assert {:error, :supervisor_not_running} =
             RuntimeShutdown.wait_for_shutdown(supervisor: Module.concat(__MODULE__, "Absent#{System.unique_integer([:positive])}"))
  end

  test "wait_for_shutdown honors an exact-instance request: guarded stop, released lease", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    task =
      Task.async(fn ->
        RuntimeShutdown.wait_for_shutdown(
          supervisor: supervisor,
          poll_ms: 20,
          holder: holder,
          snapshot: drained_snapshot(),
          application_stop: production_stop_sequence(supervisor, holder)
        )
      end)

    assert {:ok, _} = RuntimeShutdown.request(root, "operator: run complete", requested_by: "operator-console")

    assert :ok = Task.await(task, 10_000)
    assert {:error, :not_found} = RuntimeLease.observe(root)
    refute Process.whereis(supervisor)
    refute Process.whereis(holder)
    assert match?({:error, :enoent}, read_request_file(root))
  end

  test "wait_for_shutdown ignores and preserves a foreign-instance request", %{root: root} do
    holder = start_holder(root)
    supervisor = start_test_supervisor()

    task =
      Task.async(fn ->
        RuntimeShutdown.wait_for_shutdown(
          supervisor: supervisor,
          poll_ms: 20,
          holder: holder,
          snapshot: drained_snapshot(),
          application_stop: production_stop_sequence(supervisor, holder)
        )
      end)

    foreign_request = %{
      "schema_version" => 1,
      "kind" => "runtime-stop-request",
      "instance_id" => foreign_instance_id(),
      "reason" => "not this runtime",
      "requested_by" => "operator-console",
      "requested_at" => "2026-10-13T12:00:00Z"
    }

    File.mkdir_p!(RuntimeLease.authority_dir(root))
    foreign_raw = Jason.encode!(foreign_request, pretty: true)
    File.write!(RuntimeShutdown.stop_request_path(root), foreign_raw)

    # Several polls later the foreign request is untouched and the runtime is
    # still up with its lease.
    Process.sleep(150)
    assert {:ok, ^foreign_raw} = read_request_file(root)
    assert {:ok, _} = RuntimeLease.observe(root)
    assert Process.whereis(supervisor)

    GenServer.stop(supervisor, :normal)
    assert :ok = Task.await(task, 5_000)
  end
end
