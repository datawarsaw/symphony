defmodule SymphonyElixir.RuntimeLeaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeLease

  # mirrors the private per-process seam SymphonyElixir.RuntimeLease uses for the
  # destructive removal in force_release/2; lets these tests plant deterministic
  # removal outcomes
  @rm_hook :"$runtime_lease_force_rm_hook"

  setup do
    root = Path.join(System.tmp_dir!(), "mic-runtime-lease-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp foreign_instance_id, do: String.duplicate("f", 32)

  defp valid_lease(root, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Map.merge(
      %{
        "schema_version" => 1,
        "kind" => "runtime-authority",
        "state_root" => root,
        "instance_id" => foreign_instance_id(),
        "owner_token" => String.duplicate("a", 32),
        "os_pid" => "999999",
        "node" => "other@host",
        "hostname" => "other-host",
        "started_at" => now,
        "heartbeat_at" => now
      },
      overrides
    )
  end

  defp write_raw_lease(root, lease) do
    File.mkdir_p!(RuntimeLease.authority_dir(root))
    File.write!(RuntimeLease.authority_path(root), encode(lease))
  end

  defp encode(lease) when is_binary(lease), do: lease
  defp encode(lease) when is_map(lease), do: Jason.encode!(lease, pretty: true)

  defp raw_lease(root) do
    RuntimeLease.authority_path(root) |> File.read!() |> Jason.decode!()
  end

  defp iso(seconds_ago) do
    DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # -- acquisition --

  test "first claimant succeeds and persists the full lease", %{root: root} do
    assert {:ok, lease} = RuntimeLease.claim(root)
    assert is_binary(lease["owner_token"]) and byte_size(lease["owner_token"]) >= 32
    assert lease["kind"] == "runtime-authority"
    assert lease["state_root"] == root
    assert lease["instance_id"] == RuntimeLease.instance_id()
    assert lease["node"] == to_string(node())

    persisted = raw_lease(root)

    fields = ~w(schema_version kind state_root instance_id owner_token os_pid node hostname started_at heartbeat_at)

    for field <- fields do
      assert Map.has_key?(persisted, field), "field #{field}"
    end
  end

  test "second claimant for a held root is rejected with evidence and no token leak", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert {:error, {:runtime_authority_held, evidence}} =
             RuntimeLease.claim(root, instance_id: String.duplicate("b", 32))

    assert evidence["instance_id"] == foreign_instance_id()
    assert evidence["class"] == "active"
    refute Map.has_key?(evidence, "owner_token")
    assert raw_lease(root)["owner_token"] == lease["owner_token"]
  end

  test "a fresh claim reconstructs ownership for the same runtime instance (re-adopt)", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root)

    assert {:ok, adopted} = RuntimeLease.claim(root)
    assert adopted["instance_id"] == lease["instance_id"]
    assert adopted["started_at"] == lease["started_at"]
    refute adopted["owner_token"] == lease["owner_token"]
    assert adopted["heartbeat_at"] >= lease["heartbeat_at"]
  end

  test "claim is idempotent for a live holder: instance_id stays stable per BEAM" do
    assert RuntimeLease.instance_id() == RuntimeLease.instance_id()
  end

  test "concurrent claimants produce exactly one winner, losers fail closed", %{root: root} do
    results =
      1..12
      |> Task.async_stream(fn i -> RuntimeLease.claim(root, instance_id: "foreign-instance-#{i}") end)
      |> Enum.map(fn {:ok, result} -> result end)

    winners = Enum.filter(results, &match?({:ok, _}, &1))
    losers = Enum.filter(results, &match?({:error, _}, &1))

    assert length(winners) == 1
    assert length(losers) == 11
    {:ok, winner} = Enum.find(winners, &match?({:ok, _}, &1))
    assert raw_lease(root)["owner_token"] == winner["owner_token"]
    assert is_binary(raw_lease(root)["instance_id"])
  end

  test "claim on a foreign corrupt lease fails closed without overwriting", %{root: root} do
    write_raw_lease(root, "not json {{{")
    path = RuntimeLease.authority_path(root)

    assert {:error, {:lease_state_invalid, :corrupt_state}} =
             RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert File.read!(path) == "not json {{{"
  end

  # -- renewal --

  test "owner can renew, foreign owner cannot", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    foreign_token = String.duplicate("b", 32)
    assert {:error, :not_owner} = RuntimeLease.renew(root, foreign_token)
    assert raw_lease(root)["heartbeat_at"] == lease["heartbeat_at"]
    assert raw_lease(root)["owner_token"] == lease["owner_token"]

    assert {:ok, renewed} = RuntimeLease.renew(root, lease["owner_token"])
    assert raw_lease(root)["heartbeat_at"] == renewed["heartbeat_at"]
  end

  test "renew after the lease vanished fails closed", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
    :ok = RuntimeLease.release(root, lease["owner_token"])

    assert {:error, :lease_missing} = RuntimeLease.renew(root, lease["owner_token"])
  end

  # -- release --

  test "owner release removes the lease; a foreign token is refused and leaves it intact", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert {:error, :not_owner} = RuntimeLease.release(root, String.duplicate("b", 32))
    assert {:ok, _} = RuntimeLease.observe(root)

    assert :ok = RuntimeLease.release(root, lease["owner_token"])
    assert {:error, :not_found} = RuntimeLease.observe(root)
  end

  test "release of a free root is idempotent", %{root: root} do
    assert :ok = RuntimeLease.release(root, String.duplicate("b", 32))
  end

  test "a stale shutdown cannot delete a successor's lease", %{root: root} do
    {:ok, stale_owner} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
    stale_token = stale_owner["owner_token"]

    assert {:ok, record} =
             RuntimeLease.force_release(root, confirm: true, reason: "operator: host lost", force_active: true)

    assert {:ok, _successor} = RuntimeLease.claim(root, instance_id: String.duplicate("9", 32))

    # late release attempt by the previous owner must not touch the successor
    assert {:error, :not_owner} = RuntimeLease.release(root, stale_token)
    assert raw_lease(root)["instance_id"] == String.duplicate("9", 32)
    assert File.exists?(Path.join(RuntimeLease.authority_dir(root), "authority.recovery.json"))
    assert record["prior_state"]["owner_token"] == stale_token
  end

  # -- classification: staleness never authorizes takeover --

  test "stale heartbeat classifies as releasable but still rejects a new claimant", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
    backdate_heartbeat(root, 13 * 60 * 60)

    assert {:ok, :releasable} = RuntimeLease.classify(raw_lease(root))

    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["class"] == "releasable"
    assert evidence["instance_id"] == foreign_instance_id()

    assert {:error, {:runtime_authority_held, evidence}} =
             RuntimeLease.claim(root, instance_id: String.duplicate("b", 32))

    assert evidence["class"] == "releasable"
    assert raw_lease(root)["owner_token"] == lease["owner_token"]
  end

  test "classify/3 separates active, stale_unconfirmed, and releasable", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
    now = DateTime.utc_now()

    active = Map.put(lease, "heartbeat_at", iso(5 * 60))
    stale = Map.put(lease, "heartbeat_at", iso(60 * 60))
    gone = Map.put(lease, "heartbeat_at", iso(13 * 60 * 60))

    assert {:ok, :active} = RuntimeLease.classify(active, now)
    assert {:ok, :stale_unconfirmed} = RuntimeLease.classify(stale, now)
    assert {:ok, :releasable} = RuntimeLease.classify(gone, now)
  end

  defp backdate_heartbeat(root, seconds_ago) do
    root |> raw_lease() |> Map.put("heartbeat_at", iso(seconds_ago)) |> then(&write_raw_lease(root, &1))
  end

  # -- corrupt / torn authority fails closed --

  test "corrupt and foreign-shaped leases fail closed for every operation", %{root: root} do
    corrupt_variants = [
      {"zero_byte", ""},
      {"invalid_json", "not json {{{"},
      {"partial_json", ~s({"schema_version": 1, "kind": "runtime-auth)},
      {"missing_fields", Jason.encode!(%{"schema_version" => 1, "kind" => "runtime-authority", "state_root" => "x"})},
      {"future_schema", Jason.encode!(valid_lease("ignored", %{"schema_version" => 2}))},
      {"wrong_kind", Jason.encode!(valid_lease("ignored", %{"kind" => "something-else"}))},
      {"root_mismatch", Jason.encode!(valid_lease("some-other-root"))}
    ]

    for {label, content} <- corrupt_variants do
      write_raw_lease(root, content)

      expected = expected_read_error(label)

      assert {:error, ^expected} = RuntimeLease.claim(root, instance_id: foreign_instance_id()), label
      assert {:error, ^expected} = RuntimeLease.observe(root), label
      assert {:error, ^expected} = RuntimeLease.renew(root, String.duplicate("a", 32)), label
      assert {:error, ^expected} = RuntimeLease.release(root, String.duplicate("a", 32)), label

      # fail closed means fail closed: the corrupt residue stays on disk untouched
      assert File.read!(RuntimeLease.authority_path(root)) == content, label
    end
  end

  defp expected_read_error("zero_byte"), do: {:lease_state_invalid, :corrupt_state}
  defp expected_read_error("invalid_json"), do: {:lease_state_invalid, :corrupt_state}
  defp expected_read_error("partial_json"), do: {:lease_state_invalid, :corrupt_state}
  defp expected_read_error("missing_fields"), do: {:lease_state_invalid, :schema_invalid}
  defp expected_read_error("future_schema"), do: {:lease_state_invalid, :ambiguous_state}
  defp expected_read_error("wrong_kind"), do: {:lease_state_invalid, :ambiguous_state}
  defp expected_read_error("root_mismatch"), do: {:lease_state_invalid, :root_mismatch}

  test "an unreadable authority file fails closed", %{root: root} do
    path = RuntimeLease.authority_path(root)
    File.rm_rf!(path)
    File.mkdir_p!(path)

    assert {:error, {:lease_state_invalid, :unreadable_state}} = RuntimeLease.observe(root)
    assert {:error, {:lease_state_invalid, :unreadable_state}} = RuntimeLease.renew(root, String.duplicate("a", 32))
    assert {:error, {:lease_state_invalid, :unreadable_state}} = RuntimeLease.release(root, String.duplicate("a", 32))
    # claim's exclusive create is what observes the unreadable target
    assert {:error, {:lease_unavailable, :eisdir}} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    File.rm_rf!(path)
  end

  # -- operator recovery --

  test "force_release requires explicit confirmation and a reason", %{root: root} do
    {:ok, _} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert {:error, :recovery_unconfirmed} = RuntimeLease.force_release(root, reason: "x")
    assert {:error, :recovery_reason_required} = RuntimeLease.force_release(root, confirm: true)
    assert {:error, :recovery_reason_required} = RuntimeLease.force_release(root, confirm: true, reason: "")
    assert {:ok, _} = RuntimeLease.observe(root)
  end

  test "ordinary force_release refuses an ACTIVE lease, destroying nothing", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert {:error, {:active_lease, evidence}} =
             RuntimeLease.force_release(root,
               confirm: true,
               reason: "operator: routine cleanup",
               forced_by: "operator-console"
             )

    assert evidence["class"] == "active"
    assert evidence["instance_id"] == foreign_instance_id()
    refute Map.has_key?(evidence, "owner_token")

    assert raw_lease(root)["owner_token"] == lease["owner_token"]
    assert {:ok, _} = RuntimeLease.renew(root, lease["owner_token"])
    refute File.exists?(Path.join(RuntimeLease.authority_dir(root), "authority.recovery.json"))
  end

  test "force_release clears a held root, preserves evidence, and unblocks a fresh claim", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())

    assert {:ok, record} =
             RuntimeLease.force_release(root,
               confirm: true,
               reason: "operator: owner host lost mid-run",
               forced_by: "operator-console",
               force_active: true
             )

    assert record["reason"] == "operator: owner host lost mid-run"
    assert record["forced_by"] == "operator-console"
    assert record["force_active"] == true
    assert record["prior_class"] == "active"
    assert record["prior_state"]["owner_token"] == lease["owner_token"]
    assert record["prior_state"]["instance_id"] == foreign_instance_id()

    recovery_path = Path.join(RuntimeLease.authority_dir(root), "authority.recovery.json")
    assert File.exists?(recovery_path)
    assert {:error, :not_found} = RuntimeLease.observe(root)

    assert {:ok, _} = RuntimeLease.claim(root, instance_id: String.duplicate("b", 32))
  end

  test "force_release of corrupt state preserves the raw bytes as evidence", %{root: root} do
    write_raw_lease(root, "torn write {{{")

    assert {:ok, record} = RuntimeLease.force_release(root, confirm: true, reason: "operator: torn state")
    assert record["prior_class"] == "corrupt_state"
    assert record["prior_state"] == "torn write {{{"

    assert {:error, :not_found} = RuntimeLease.observe(root)
  end

  test "force_release of a missing lease reports lease_missing", %{root: root} do
    assert {:error, :lease_missing} = RuntimeLease.force_release(root, confirm: true, reason: "operator: probe")
  end

  test "force_release reports removal failure instead of success and leaves the lease intact", %{root: root} do
    {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
    Process.put(@rm_hook, fn _path -> {:error, :eacces} end)

    assert {:error, {:lease_remove_failed, record}} =
             RuntimeLease.force_release(root, confirm: true, reason: "operator: host lost", force_active: true)

    assert record["remove_error"] == :eacces
    assert record["prior_state"]["owner_token"] == lease["owner_token"]

    assert raw_lease(root)["owner_token"] == lease["owner_token"]
    assert {:ok, _} = RuntimeLease.renew(root, lease["owner_token"])
  after
    Process.delete(@rm_hook)
  end

  test "force_release fails closed on a lease that survives removal", %{root: root} do
    for {expected_kind, plant} <- [
          {:same_lease, fn lease -> lease end},
          {:newer_lease,
           fn lease ->
             %{lease | "owner_token" => String.duplicate("9", 32), "instance_id" => String.duplicate("9", 32)}
           end},
          {:corrupt_state, fn _lease -> :garbage end}
        ] do
      {:ok, lease} = RuntimeLease.claim(root, instance_id: foreign_instance_id())
      path = RuntimeLease.authority_path(root)
      planted = plant.(lease)

      Process.put(@rm_hook, fn _p ->
        File.rm!(path)

        if planted == :garbage do
          File.write!(path, "garbage{{{")
        else
          File.write!(path, Jason.encode!(planted, pretty: true))
        end

        :ok
      end)

      assert {:error, {:lease_survived, ^expected_kind, _evidence}} =
               RuntimeLease.force_release(root, confirm: true, reason: "operator: probe", force_active: true),
             "expected #{inspect(expected_kind)} survivor classification"

      assert File.exists?(path)
      Process.delete(@rm_hook)
      _ = RuntimeLease.force_release(root, confirm: true, reason: "test cleanup", force_active: true)
      :ok
    end
  after
    Process.delete(@rm_hook)
  end

  test "force_release racing a live renewer never reports success while the owner survives", %{root: root} do
    for round <- 1..5 do
      {:ok, lease} = RuntimeLease.claim(root, instance_id: "foreign-racer-#{round}")
      token = lease["owner_token"]
      renewer = spawn(fn -> renew_loop(root, token) end)

      assert {:error, {:active_lease, _}} = RuntimeLease.force_release(root, confirm: true, reason: "operator: probe")
      assert {:ok, _} = RuntimeLease.renew(root, token)

      assert {:ok, _} = RuntimeLease.force_release(root, confirm: true, reason: "operator: probe", force_active: true)
      send(renewer, :stop)
      assert {:error, :not_found} = RuntimeLease.observe(root)
      assert {:error, :lease_missing} = RuntimeLease.renew(root, token)
    end
  end

  defp renew_loop(root, token) do
    receive do
      :stop -> :ok
    after
      0 ->
        _ = RuntimeLease.renew(root, token)
        Process.sleep(5)
        renew_loop(root, token)
    end
  end

  # -- op lock contention --

  test "claim waits for a held op lock and proceeds once free", %{root: root} do
    File.mkdir_p!(RuntimeLease.authority_dir(root))
    op_lock = Path.join(RuntimeLease.authority_dir(root), "authority.op-lock")
    {:ok, io} = :file.open(op_lock, [:raw, :write, :exclusive])
    :file.write(io, "held")

    claimant =
      Task.async(fn -> RuntimeLease.claim(root, instance_id: foreign_instance_id()) end)

    Process.sleep(100)
    refute Task.yield(claimant, 0), "claim must wait for the op lock"
    :file.close(io)
    _ = File.rm(op_lock)

    assert {:ok, _lease} = Task.await(claimant)
  end

  test "claim fails closed when the op lock is held beyond the budget", %{root: root} do
    File.mkdir_p!(RuntimeLease.authority_dir(root))
    op_lock = Path.join(RuntimeLease.authority_dir(root), "authority.op-lock")
    {:ok, io} = :file.open(op_lock, [:raw, :write, :exclusive])
    :file.write(io, "held")

    assert {:error, {:lease_op_lock_unavailable, :timeout}} =
             RuntimeLease.claim(root, instance_id: foreign_instance_id(), lock_timeout_ms: 50)

    :file.close(io)
    _ = File.rm(op_lock)
  end

  # -- holder (acquire_and_hold / authoritative? / status / release_held) --

  test "status, authoritative?, and release_held on a dead holder are inert" do
    dead = Module.concat(__MODULE__, "NoHolder#{System.unique_integer([:positive])}")

    assert :unavailable = RuntimeLease.status(dead)
    refute RuntimeLease.authoritative?(dead)
    assert :ok = RuntimeLease.release_held(dead)
  end

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

  test "holder acquires and reports held status", %{root: root} do
    opts = holder_opts(root)
    name = opts[:name]

    assert {:ok, _pid} = RuntimeLease.acquire_and_hold(opts)
    assert RuntimeLease.authoritative?(name)

    assert {:ok, status} = RuntimeLease.status(name)
    assert status.held?
    refute status.lost?
    assert status.root == root
    assert is_binary(status.instance_id)
    assert is_binary(status.started_at)
    assert status.class == :active
    refute Map.has_key?(status, :owner_token)

    # file evidence agrees with the holder
    assert {:ok, evidence} = RuntimeLease.observe(root)
    assert evidence["instance_id"] == status.instance_id

    assert :ok = RuntimeLease.release_held(name)
    assert {:error, :not_found} = RuntimeLease.observe(root)
    refute RuntimeLease.authoritative?(name)
  end

  test "acquire_and_hold fails closed against a foreign lease", %{root: root} do
    write_raw_lease(root, valid_lease(root))
    opts = holder_opts(root)

    assert {:error, {:runtime_authority_unavailable, {:runtime_authority_held, evidence}}} =
             RuntimeLease.acquire_and_hold(opts)

    assert evidence["instance_id"] == foreign_instance_id()
    refute Process.whereis(opts[:name])
  end

  test "acquire_and_hold is idempotent for an already-authoritative holder", %{root: root} do
    opts = holder_opts(root)
    {:ok, pid} = RuntimeLease.acquire_and_hold(opts)

    assert {:ok, ^pid} = RuntimeLease.acquire_and_hold(opts)
    :ok = RuntimeLease.release_held(opts[:name])
  end

  test "heartbeat renews the lease", %{root: root} do
    opts = holder_opts(root, heartbeat_ms: 30)
    name = opts[:name]

    # claim as this BEAM's own instance so the holder can re-adopt the residue
    assert {:ok, lease} = RuntimeLease.claim(root)
    started_heartbeat = lease["heartbeat_at"]

    assert {:ok, _pid} = RuntimeLease.acquire_and_hold(opts)
    assert {:ok, status} = RuntimeLease.status(name)
    assert status.class == :active

    wait_until(2_000, fn ->
      case RuntimeLease.status(name) do
        {:ok, %{last_renew_at: at}} when is_binary(at) -> true
        _ -> false
      end
    end)

    # heartbeat_at is second-truncated, so equality is possible; last_renew_at set
    # at all proves a renewal happened, and the file never moves backwards.
    assert raw_lease(root)["heartbeat_at"] >= started_heartbeat
    :ok = RuntimeLease.release_held(name)
  end

  test "authority loss stops the holder, marks the instance lost, and refuses re-acquisition", %{root: root} do
    opts = holder_opts(root, heartbeat_ms: 20)
    name = opts[:name]

    Process.flag(:trap_exit, true)
    {:ok, pid} = RuntimeLease.acquire_and_hold(opts)

    # simulate a lost lease: the authoritative file disappears under the holder
    :ok = File.rm(RuntimeLease.authority_path(root))

    assert_receive {:EXIT, ^pid, {:runtime_authority_lost, :lease_missing}}, 5_000
    refute Process.alive?(pid)
    refute RuntimeLease.authoritative?(name)

    # a restarted holder in the same BEAM must not silently re-acquire
    assert {:error, {:runtime_authority_lost, ^root}} = RuntimeLease.acquire_and_hold(opts)
  end

  test "transient renewal failures retry; persistent ones fail closed", %{root: root} do
    previous = Application.get_env(:symphony_elixir, :runtime_lease_max_renew_failures)
    Application.put_env(:symphony_elixir, :runtime_lease_max_renew_failures, 4)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :runtime_lease_max_renew_failures)
      else
        Application.put_env(:symphony_elixir, :runtime_lease_max_renew_failures, previous)
      end
    end)

    opts = holder_opts(root, heartbeat_ms: 30)
    name = opts[:name]
    Process.flag(:trap_exit, true)
    {:ok, pid} = RuntimeLease.acquire_and_hold(opts)

    path = RuntimeLease.authority_path(root)
    original = File.read!(path)

    # Swap the target under :sys so no heartbeat observes the intermediate
    # (missing) state: a missing lease is terminal by design, and the point here
    # is the unreadable-but-present filesystem failure.
    plant_unreadable = fn ->
      :sys.suspend(pid)
      File.rm_rf!(path)
      File.mkdir_p!(path)
      :sys.resume(pid)
    end

    # an unreadable target is a filesystem failure, not an ownership answer:
    # the holder keeps running and keeps retrying
    plant_unreadable.()

    wait_until(2_000, fn ->
      match?({:ok, %{renew_error: {:lease_state_invalid, :unreadable_state}}}, RuntimeLease.status(name))
    end)

    assert Process.alive?(pid)
    assert RuntimeLease.authoritative?(name)

    # repair the target (restore the exact prior lease): the next heartbeat
    # recovers and the failure count resets
    :sys.suspend(pid)
    File.rm_rf!(path)
    File.write!(path, original)
    :sys.resume(pid)

    wait_until(2_000, fn ->
      match?({:ok, %{renew_error: nil, last_renew_at: at}} when is_binary(at), RuntimeLease.status(name))
    end)

    # persistent failures (the terminal budget) still fail closed
    plant_unreadable.()

    assert_receive {:EXIT, ^pid, {:runtime_authority_lost, {:lease_state_invalid, :unreadable_state}}}, 5_000
  end

  test "a foreign lease appearing mid-run fails the holder closed immediately", %{root: root} do
    opts = holder_opts(root, heartbeat_ms: 30)
    name = opts[:name]
    Process.flag(:trap_exit, true)
    {:ok, pid} = RuntimeLease.acquire_and_hold(opts)

    write_raw_lease(root, valid_lease(root, %{"owner_token" => String.duplicate("d", 32)}))

    assert_receive {:EXIT, ^pid, {:runtime_authority_lost, :not_owner}}, 5_000
    refute RuntimeLease.authoritative?(name)
  end

  test "authority loss stops the configured runtime supervisor", %{root: root} do
    supervisor_name = Module.concat(__MODULE__, "GatedSup#{System.unique_integer([:positive])}")
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one, name: supervisor_name)

    opts = holder_opts(root, heartbeat_ms: 20, runtime_supervisor: supervisor_name)
    Process.flag(:trap_exit, true)
    {:ok, pid} = RuntimeLease.acquire_and_hold(opts)

    :ok = File.rm(RuntimeLease.authority_path(root))

    assert_receive {:EXIT, ^sup, :runtime_authority_lost}, 5_000
    assert_receive {:EXIT, ^pid, {:runtime_authority_lost, :lease_missing}}, 5_000
  end

  defp wait_until(timeout, _fun) when timeout <= 0, do: flunk("condition not met in time")

  defp wait_until(timeout, fun) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(timeout - 50, fun)
    end
  end
end
