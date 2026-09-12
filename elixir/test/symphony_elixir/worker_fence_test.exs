defmodule SymphonyElixir.WorkerFenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkerFence

  test "absent identities are unknown and fail closed" do
    assert WorkerFence.confirm_dead(nil) == {:error, :unknown}
    assert WorkerFence.confirm_dead("") == {:error, :unknown}
  end

  test "live local pids are alive" do
    assert WorkerFence.confirm_dead(self()) == {:error, :alive}
  end

  test "exited local pids are positively proven dead" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute Process.alive?(pid)
    assert WorkerFence.confirm_dead(pid) == {:ok, :dead}
  end

  test "opaque identities are unknown and must fail closed" do
    assert WorkerFence.confirm_dead("worker-host-1") == {:error, :unknown}
    assert WorkerFence.confirm_dead({:worker, make_ref()}) == {:error, :unknown}
    assert WorkerFence.confirm_dead(123) == {:error, :unknown}
  end

  test "explicit never-spawned evidence is positively proven dead and safe to dispatch" do
    assert WorkerFence.confirm_never_spawned(:never_spawned) == {:ok, :dead}
  end

  test "never-spawned death is never inferred from absent or malformed identities" do
    assert WorkerFence.confirm_never_spawned(nil) == {:error, :unknown}
    assert WorkerFence.confirm_never_spawned("") == {:error, :unknown}
    assert WorkerFence.confirm_never_spawned("worker-host-1") == {:error, :unknown}
    assert WorkerFence.confirm_never_spawned(self()) == {:error, :unknown}
  end
end
