defmodule SymphonyElixir.SteeringStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SteeringStore

  setup do
    root = Path.join(System.tmp_dir!(), "mic10-steering-store-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "steering_dir/1 lives under .symphony-state", %{root: root} do
    assert SteeringStore.steering_dir(root) == Path.join([root, ".symphony-state", "steering"])
  end

  test "safe_steer_id/1 normalizes identifiers" do
    assert SteeringStore.safe_steer_id("STEER-123.Foo!") == "steer-123_foo_"
    assert String.length(SteeringStore.safe_steer_id(String.duplicate("a", 500))) <= 128
  end

  test "write/read round-trip preserves the record", %{root: root} do
    assert SteeringStore.schema_version() == 1

    record = %{
      "schema_version" => 1,
      "steer_id" => "steer-1",
      "issue_id" => "ISS-1",
      "status" => "PENDING",
      "instruction" => "focus on tests"
    }

    assert :ok = SteeringStore.write_record(root, record)
    assert {:ok, saved} = SteeringStore.read_record(root, "steer-1")
    assert saved["steer_id"] == "steer-1"
    assert saved["status"] == "PENDING"
    assert saved["instruction"] == "focus on tests"
    assert String.ends_with?(SteeringStore.record_path(root, "steer-1"), "steer-1.json")
  end

  test "read_record/2 fails closed on missing, corrupt, and ambiguous records", %{root: root} do
    assert {:error, :not_found} = SteeringStore.read_record(root, "missing")

    corrupt_path = SteeringStore.record_path(root, "broken")
    File.mkdir_p!(Path.dirname(corrupt_path))
    File.write!(corrupt_path, "{not json")
    assert {:error, :corrupt_state} = SteeringStore.read_record(root, "broken")

    ambiguous_path = SteeringStore.record_path(root, "ambiguous")
    File.write!(ambiguous_path, Jason.encode!(%{"unexpected" => true}))
    assert {:error, :ambiguous_state} = SteeringStore.read_record(root, "ambiguous")
  end

  test "list_records/1 returns every stored record and skips missing directory", %{root: root} do
    assert [] = SteeringStore.list_records(root)

    :ok = SteeringStore.write_record(root, %{"schema_version" => 1, "steer_id" => "a", "status" => "PENDING"})
    :ok = SteeringStore.write_record(root, %{"schema_version" => 1, "steer_id" => "b", "status" => "STALE"})

    results = SteeringStore.list_records(root)
    assert length(results) == 2
    assert Enum.all?(results, fn {_id, result} -> match?({:ok, _}, result) end)
  end

  test "list_records/1 reports corrupt files instead of dropping them", %{root: root} do
    :ok = SteeringStore.write_record(root, %{"schema_version" => 1, "steer_id" => "good", "status" => "PENDING"})
    File.write!(SteeringStore.record_path(root, "bad"), "garbage")

    results = SteeringStore.list_records(root)
    assert {:ok, _} = results |> Enum.find(fn {id, _} -> id == "good" end) |> elem(1)
    assert {:error, :corrupt_state} = results |> Enum.find(fn {id, _} -> id == "bad" end) |> elem(1)
  end
end
