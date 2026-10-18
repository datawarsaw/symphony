defmodule SymphonyElixir.RetryStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RetryStore

  setup do
    root = Path.join(System.tmp_dir!(), "mic195-retry-store-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "safe_issue_id/1 normalizes identifiers", %{root: _root} do
    assert RetryStore.safe_issue_id("MT-123_Foo.Bar!") == "mt-123_foo_bar_"
    assert RetryStore.safe_issue_id("abc") == "abc"
  end

  test "write/read round-trip preserves the record", %{root: root} do
    assert RetryStore.schema_version() == 1

    record = RetryStore.build_record(%{issue_id: "ISS-1", identifier: "MT-1", status: "retrying", failure_class: "PROVIDER_QUOTA", attempt_count: 2, workspace_root: root})
    assert :ok = RetryStore.write_record(root, record)
    assert {:ok, saved} = RetryStore.read_record(root, "ISS-1")
    assert saved["schema_version"] == 1
    assert saved["issue_id"] == "ISS-1"
    assert saved["status"] == "retrying"
    assert saved["attempt_count"] == 2
    assert {:ok, _, _} = DateTime.from_iso8601(saved["first_failure_at"])
    assert {:ok, _, _} = DateTime.from_iso8601(saved["last_failure_at"])
    assert String.ends_with?(RetryStore.record_path(root, "ISS-1"), "iss-1.json")
  end

  test "build_record/1 fills defaults", %{root: _root} do
    record = RetryStore.build_record(%{issue_id: "ISS-D", status: "parked", failure_class: "AUTH_UNAVAILABLE"})
    assert record["identifier"] == ""
    assert record["attempt_count"] == 0
    assert record["identical_failure_count"] == 1
    assert record["workspace_root"] == ""
    assert record["worker_identity"] == nil
  end

  test "build_record/1 carries an optional worker identity without schema churn", %{root: _root} do
    record = RetryStore.build_record(%{issue_id: "ISS-D", status: "retrying", failure_class: "PROVIDER_OUTAGE", worker_identity: "never_spawned"})
    assert record["worker_identity"] == "never_spawned"
    assert record["schema_version"] == 1
  end

  test "atomic replacement: rewriting a record replaces it and leaves no temp files", %{root: root} do
    first = RetryStore.build_record(%{issue_id: "ISS-REPL", identifier: "MT-REPL", status: "retrying", failure_class: "PROVIDER_OUTAGE", attempt_count: 1})
    :ok = RetryStore.write_record(root, first)

    second =
      RetryStore.build_record(%{issue_id: "ISS-REPL", identifier: "MT-REPL", status: "parked", failure_class: "PROVIDER_OUTAGE", attempt_count: 4, worker_identity: "never_spawned"})

    :ok = RetryStore.write_record(root, second)

    assert {:ok, saved} = RetryStore.read_record(root, "ISS-REPL")
    assert saved["status"] == "parked"
    assert saved["attempt_count"] == 4
    assert saved["worker_identity"] == "never_spawned"

    assert {:ok, entries} = RetryStore.list_records(root)
    assert length(entries) == 1
    assert {"iss-repl", {:ok, _record}} = hd(entries)
  end

  test "read_record/2 reports missing, corrupt, and ambiguous state", %{root: root} do
    assert RetryStore.read_record(root, "nope") == {:error, :not_found}

    File.mkdir_p!(RetryStore.retries_dir(root))
    File.write!(RetryStore.record_path(root, "bad"), "not json{{{")
    assert RetryStore.read_record(root, "bad") == {:error, :corrupt_state}

    File.write!(RetryStore.record_path(root, "future"), Jason.encode!(%{"schema_version" => 2}))
    assert RetryStore.read_record(root, "future") == {:error, :ambiguous_state}
  end

  test "read_record/2 reports unreadable state", %{root: root} do
    File.mkdir_p!(RetryStore.record_path(root, "adir"))
    assert RetryStore.read_record(root, "adir") == {:error, :unreadable_state}
  end

  test "list_records/1 distinguishes a missing directory from an unreadable directory", %{root: root} do
    assert {:ok, []} = RetryStore.list_records(Path.join(root, "missing"))

    File.write!(Path.join(root, "not-a-directory"), "file")

    assert {:error, {:retry_directory_unreadable, _reason}} =
             RetryStore.list_records(Path.join(root, "not-a-directory"))

    record = RetryStore.build_record(%{issue_id: "ISS-L", status: "parked", failure_class: "AUTH_UNAVAILABLE"})
    :ok = RetryStore.write_record(root, record)
    File.write!(Path.join(RetryStore.retries_dir(root), "notes.txt"), "hi")
    File.mkdir_p!(Path.join(RetryStore.retries_dir(root), "weird.json"))

    assert {:ok, records} = RetryStore.list_records(root)
    entries = Map.new(records)
    assert {:ok, _} = Map.fetch!(entries, "iss-l")
    assert {:error, :unreadable_state} = Map.fetch!(entries, "weird")
    refute Map.has_key?(entries, "notes.txt")
  end

  test "list_records/1 fails closed on corrupt and ambiguous payloads", %{root: root} do
    File.mkdir_p!(RetryStore.retries_dir(root))
    File.write!(Path.join(RetryStore.retries_dir(root), "broken.json"), "not json{{{")
    File.write!(Path.join(RetryStore.retries_dir(root), "future.json"), Jason.encode!(%{"schema_version" => 2}))
    assert {:ok, records} = RetryStore.list_records(root)
    entries = Map.new(records)
    assert {:error, :corrupt_state} = Map.fetch!(entries, "broken")
    assert {:error, :ambiguous_state} = Map.fetch!(entries, "future")
  end

  test "delete_record/1 removes durable state idempotently", %{root: root} do
    record = RetryStore.build_record(%{issue_id: "ISS-X", status: "retrying", failure_class: "PROVIDER_OUTAGE"})
    :ok = RetryStore.write_record(root, record)
    assert :ok = RetryStore.delete_record(root, "ISS-X")
    assert RetryStore.read_record(root, "ISS-X") == {:error, :not_found}
    assert :ok = RetryStore.delete_record(root, "ISS-X")
  end

  test "read and enumeration reject a record whose file identity disagrees with issue_id", %{root: root} do
    File.mkdir_p!(RetryStore.retries_dir(root))
    record = RetryStore.build_record(%{issue_id: "ISS-ACTUAL", status: "parked", failure_class: "AUTH_UNAVAILABLE"})
    File.write!(Path.join(RetryStore.retries_dir(root), "iss-file.json"), Jason.encode!(record))

    assert {:error, :identity_mismatch} = RetryStore.read_record(root, "ISS-FILE")
    assert {:ok, [{"iss-file", {:error, :identity_mismatch}}]} = RetryStore.list_records(root)
  end

  test "read rejects invalid status, counters, and timestamp order without altering evidence", %{root: root} do
    File.mkdir_p!(RetryStore.retries_dir(root))

    invalid = %{
      "schema_version" => 1,
      "issue_id" => "ISS-INVALID",
      "status" => "complete",
      "failure_class" => "PROVIDER_OUTAGE",
      "attempt_count" => -1,
      "identical_failure_count" => 0,
      "first_failure_at" => "2026-10-17T12:01:00Z",
      "last_failure_at" => "2026-10-17T12:00:00Z"
    }

    path = RetryStore.record_path(root, "ISS-INVALID")
    File.write!(path, Jason.encode!(invalid))

    assert {:error, :ambiguous_state} = RetryStore.read_record(root, "ISS-INVALID")
    assert File.read!(path) == Jason.encode!(invalid)
  end

  test "write returns an explicit failure and retains an existing record when validation fails", %{root: root} do
    original = RetryStore.build_record(%{issue_id: "ISS-DURABLE", status: "parked", failure_class: "AUTH_UNAVAILABLE"})
    assert :ok = RetryStore.write_record(root, original)

    invalid = Map.put(original, "status", "complete")
    assert {:error, :ambiguous_state} = RetryStore.write_record(root, invalid)
    assert {:ok, ^original} = RetryStore.read_record(root, "ISS-DURABLE")
  end

  test "write preserves corrupt existing evidence instead of replacing it", %{root: root} do
    File.mkdir_p!(RetryStore.retries_dir(root))
    path = RetryStore.record_path(root, "ISS-QUESTIONABLE")
    corrupt = "not json{{{"
    File.write!(path, corrupt)

    replacement =
      RetryStore.build_record(%{
        issue_id: "ISS-QUESTIONABLE",
        status: "parked",
        failure_class: "AUTH_UNAVAILABLE"
      })

    assert {:error, :existing_record_untrusted} = RetryStore.write_record(root, replacement)
    assert File.read!(path) == corrupt
  end

  test "write returns an explicit filesystem failure without raising", %{root: root} do
    blocked_root = Path.join(root, "not-a-directory")
    File.write!(blocked_root, "file")
    record = RetryStore.build_record(%{issue_id: "ISS-BLOCKED", status: "parked", failure_class: "AUTH_UNAVAILABLE"})

    assert {:error, _reason} = RetryStore.write_record(blocked_root, record)
  end
end
