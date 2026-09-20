defmodule SymphonyElixir.LaunchMarkerTest do
  use SymphonyElixir.TestSupport

  # Hardening slice: durable launch marker storage and the resume/cleanup
  # fence over it. The fence verdicts themselves come from WorkerFence /
  # WorkerContainment receipt verification; these tests pin the marker's
  # storage contract and its fail-closed gate semantics.

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.WorkerContainment

  setup do
    root =
      Path.join(System.tmp_dir!(), "symphony-launch-markers-#{System.unique_integer([:positive])}")

    Application.put_env(:symphony_elixir, :launch_marker_root, root)
    receipts = Path.join(root, "receipts")
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      File.rm_rf(root)
    end)

    %{root: root, receipts: receipts}
  end

  defp new_identity(issue_id) do
    WorkerContainment.new_identity(
      issue_id: issue_id,
      attempt_id: 1,
      workspace: Path.join(["C:", "tmp", "ws", issue_id]),
      worker_host: nil
    )
  end

  defp write_receipt(dir, launch_id, overrides \\ %{}) do
    File.mkdir_p!(dir)

    receipt =
      Map.merge(
        %{
          "schema_version" => 1,
          "launch_id" => launch_id,
          "tree_drained" => true,
          "terminal_reason" => "NATURAL_EXIT",
          "termination_mode" => "cooperative",
          "child_exit_code" => 0
        },
        overrides
      )

    path = Path.join(dir, launch_id <> ".json")
    File.write!(path, Jason.encode!(receipt))
    path
  end

  describe "record/read/clear" do
    test "record writes a durable marker that round-trips through read", %{root: root} do
      identity = new_identity("issue-record")

      assert :ok = LaunchMarker.record(identity, identifier: "MT-1", attempt_id: 3)

      assert {:ok, marker} = LaunchMarker.read("issue-record")
      assert marker["schema_version"] == 1
      assert marker["issue_id"] == "issue-record"
      assert marker["identifier"] == "MT-1"
      assert marker["attempt_id"] == 3
      assert marker["launch_id"] == identity["launch_id"]
      assert marker["workspace"] == identity["workspace"]
      assert marker["worker_identity"] == identity
      assert marker["workspace_key"] == Path.basename(identity["workspace"])
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(marker["started_at"])
      assert File.exists?(LaunchMarker.marker_path("issue-record"))

      assert String.downcase(Path.dirname(LaunchMarker.marker_path("issue-record"))) ==
               String.downcase(Path.expand(root))
    end

    test "record replaces the previous launch's marker for the same issue" do
      assert :ok = LaunchMarker.record(new_identity("issue-replace"), identifier: "MT-2")
      assert {:ok, first} = LaunchMarker.read("issue-replace")

      assert :ok = LaunchMarker.record(new_identity("issue-replace"), identifier: "MT-2")
      assert {:ok, second} = LaunchMarker.read("issue-replace")

      refute second["launch_id"] == first["launch_id"]
    end

    test "record rejects an identity that cannot be fenced" do
      unkeyed = Map.put(new_identity("issue-unkeyed"), "issue_id", nil)
      assert {:error, :launch_marker_identity_invalid} = LaunchMarker.record(unkeyed)

      no_launch_id = Map.put(new_identity("issue-nolaunch"), "launch_id", "")
      assert {:error, :launch_marker_identity_invalid} = LaunchMarker.record(no_launch_id)
    end

    test "read fails closed on corrupt or ambiguous marker files" do
      path = LaunchMarker.marker_path("issue-corrupt")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      assert {:error, :corrupt} = LaunchMarker.read("issue-corrupt")

      File.write!(path, Jason.encode!(%{"schema_version" => 2, "issue_id" => "issue-corrupt"}))
      assert {:error, :corrupt} = LaunchMarker.read("issue-corrupt")
    end

    test "read returns not_found for absent and unkeyed issues" do
      assert {:error, :not_found} = LaunchMarker.read("issue-absent")
      assert {:error, :not_found} = LaunchMarker.read(nil)
    end

    test "clear removes the marker and is idempotent" do
      assert :ok = LaunchMarker.record(new_identity("issue-clear"), identifier: "MT-3")
      assert :ok = LaunchMarker.clear("issue-clear")
      assert {:error, :not_found} = LaunchMarker.read("issue-clear")
      assert :ok = LaunchMarker.clear("issue-clear")
      assert :ok = LaunchMarker.clear(nil)
    end

    test "record_wrapper_identity refreshes the stored identity for the same launch only" do
      identity = new_identity("issue-wrapper")
      assert :ok = LaunchMarker.record(identity, identifier: "MT-4")

      updated = Map.put(identity, "wrapper_pid", "4242")
      assert :ok = LaunchMarker.record_wrapper_identity(updated)
      assert {:ok, %{"worker_identity" => stored}} = LaunchMarker.read("issue-wrapper")
      assert stored["wrapper_pid"] == "4242"

      # A stale refresh (older launch id) never overwrites a newer marker.
      assert :ok = LaunchMarker.record(new_identity("issue-wrapper"), identifier: "MT-4")
      assert :ok = LaunchMarker.record_wrapper_identity(identity)
      assert {:ok, %{"launch_id" => current, "worker_identity" => stored2}} = LaunchMarker.read("issue-wrapper")
      refute stored2 == identity
      assert current != identity["launch_id"]
    end
  end

  describe "reuse_gate / cleanup_gate" do
    test "no marker allows dispatch and cleanup" do
      assert :allowed = LaunchMarker.reuse_gate("issue-never")
      assert :allowed = LaunchMarker.cleanup_gate("issue-never")
    end

    test "marker without a receipt is UNKNOWN and blocks both gates" do
      assert :ok = LaunchMarker.record(new_identity("issue-unproven"), identifier: "MT-5")

      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate("issue-unproven")
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate("issue-unproven")
    end

    test "marker with a proven termination receipt allows both gates", %{receipts: receipts} do
      identity = new_identity("issue-proven")
      assert :ok = LaunchMarker.record(identity, identifier: "MT-6")
      write_receipt(receipts, identity["launch_id"])

      assert :allowed = LaunchMarker.reuse_gate("issue-proven")
      assert :allowed = LaunchMarker.cleanup_gate("issue-proven")
    end

    test "corrupt marker blocks both gates" do
      path = LaunchMarker.marker_path("issue-garbage")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "garbage")

      assert {:blocked, :launch_marker_unreadable} = LaunchMarker.reuse_gate("issue-garbage")
      assert {:blocked, :launch_marker_unreadable} = LaunchMarker.cleanup_gate("issue-garbage")
    end

    test "receipt with wrong launch id stays UNKNOWN and blocks", %{receipts: receipts} do
      identity = new_identity("issue-wrong-receipt")
      assert :ok = LaunchMarker.record(identity, identifier: "MT-7")
      write_receipt(receipts, "a-different-launch")

      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate("issue-wrong-receipt")
    end

    test "unproven receipt (tree not drained) stays UNKNOWN and blocks", %{receipts: receipts} do
      identity = new_identity("issue-not-drained")
      assert :ok = LaunchMarker.record(identity, identifier: "MT-8")
      write_receipt(receipts, identity["launch_id"], %{"tree_drained" => false, "terminal_reason" => "NATURAL_EXIT"})

      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate("issue-not-drained")
    end
  end

  describe "fence_verdict" do
    test "missing marker is UNKNOWN, never death" do
      assert {:error, :unknown} = LaunchMarker.fence_verdict("issue-missing-verdict")
    end

    test "proven receipt is dead; missing receipt is unknown", %{receipts: receipts} do
      identity = new_identity("issue-verdict")
      assert :ok = LaunchMarker.record(identity, identifier: "MT-9")
      assert {:error, :unknown} = LaunchMarker.fence_verdict("issue-verdict")

      write_receipt(receipts, identity["launch_id"])
      assert {:ok, :dead} = LaunchMarker.fence_verdict("issue-verdict")
    end
  end
end
