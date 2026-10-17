defmodule SymphonyElixir.WorkerContainmentReceiptIdentityTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  BEAM termination-receipt confirmation must bind the embedded launch_id to the
  expected launch identity before it can return TERMINATED_CONFIRMED or clear
  a LaunchMarker.
  """

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.WorkerContainment

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-receipt-identity-#{System.unique_integer([:positive])}")
    receipts = Path.join(root, "receipts")
    markers = Path.join(root, "markers")
    File.mkdir_p!(receipts)
    File.mkdir_p!(markers)

    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)
    Application.put_env(:symphony_elixir, :launch_marker_root, markers)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_containment_tasklist_probe)
      Application.delete_env(:symphony_elixir, :worker_termination_hard_budget_ms)
      File.rm_rf(root)
    end)

    :ok
  end

  test "matching launch_id confirms termination on the BEAM and managed paths" do
    identity = new_identity("issue-match")
    write_receipt(identity["receipt_path"], identity["launch_id"], %{"child_exit_code" => 0})

    confirmation = stop_and_confirm(identity)

    assert confirmation.status == :TERMINATED_CONFIRMED
    assert confirmation.reason == "NATURAL_EXIT"
    assert confirmation.exit_code == 0
    assert confirmation.receipt["launch_id"] == identity["launch_id"]
    assert WorkerContainment.classify_receipt(confirmation.receipt) == :TERMINATED_CONFIRMED
    assert WorkerContainment.verify_identity_receipt(identity) == {:ok, :dead}
    assert WorkerContainment.reuse_gate(confirmation, :MANAGED_CONFIRMATION_REQUIRED) == :allowed
    assert Orchestrator.managed_receipt_confirmation_for_test(identity) == confirmation
  end

  test "correct filename with a mismatched embedded launch_id is rejected and keeps the marker" do
    identity = new_identity("issue-mismatch")
    assert :ok = LaunchMarker.record(identity, identifier: "MIS-1")
    write_receipt(identity["receipt_path"], "other-launch")

    assert WorkerContainment.classify_receipt(Jason.decode!(File.read!(identity["receipt_path"]))) ==
             :TERMINATED_CONFIRMED

    assert WorkerContainment.verify_identity_receipt(identity) == {:error, :unknown}
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(identity["issue_id"])

    confirmation = AppServer.stop_session(%{port: open_port(), worker_identity: identity})

    assert confirmation.status == :TERMINATION_UNCONFIRMED
    assert confirmation.reason == :receipt_not_proven
    assert confirmation.receipt["launch_id"] == "other-launch"

    assert WorkerContainment.reuse_gate(confirmation, :MANAGED_CONFIRMATION_REQUIRED) ==
             {:blocked, :worker_termination_unconfirmed}

    assert {:ok, marker} = LaunchMarker.read(identity["issue_id"])
    assert marker["launch_id"] == identity["launch_id"]
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(identity["issue_id"])

    assert %{status: :TERMINATION_UNCONFIRMED, reason: :receipt_not_proven} =
             Orchestrator.managed_receipt_confirmation_for_test(identity)
  end

  test "empty or missing launch_id is rejected" do
    identity = new_identity("issue-empty")
    assert :ok = LaunchMarker.record(identity, identifier: "EMP-1")

    write_receipt(identity["receipt_path"], "")
    assert stop_and_confirm(identity).status == :TERMINATION_UNCONFIRMED
    assert WorkerContainment.verify_identity_receipt(identity) == {:error, :unknown}
    assert %{status: :TERMINATION_UNCONFIRMED} = Orchestrator.managed_receipt_confirmation_for_test(identity)

    write_receipt(identity["receipt_path"], identity["launch_id"])
    blank_expected = Map.put(identity, "launch_id", "")
    assert stop_and_confirm(blank_expected).status == :TERMINATION_UNCONFIRMED

    assert %{status: :TERMINATION_UNCONFIRMED} =
             Orchestrator.managed_receipt_confirmation_for_test(blank_expected)

    write_receipt(identity["receipt_path"], "")
    assert stop_and_confirm(blank_expected).status == :TERMINATION_UNCONFIRMED
    assert WorkerContainment.verify_identity_receipt(blank_expected) == {:error, :unknown}

    missing_expected = Map.delete(identity, "launch_id")
    write_receipt(identity["receipt_path"], identity["launch_id"])
    assert stop_and_confirm(missing_expected).status == :TERMINATION_UNCONFIRMED

    assert %{status: :TERMINATION_UNCONFIRMED} =
             Orchestrator.managed_receipt_confirmation_for_test(missing_expected)

    File.write!(identity["receipt_path"], Jason.encode!(Map.delete(valid_body("present"), "launch_id")))
    missing_embedded = stop_with_gone_wrapper(identity)
    assert missing_embedded.status == :TERMINATION_UNCONFIRMED
    assert missing_embedded.receipt == nil
    assert Orchestrator.managed_receipt_confirmation_for_test(identity) == nil
    assert {:ok, _marker} = LaunchMarker.read(identity["issue_id"])
  end

  test "invalid tree_drained and unsupported terminal reasons stay unconfirmed" do
    identity = new_identity("issue-unproven")

    write_receipt(identity["receipt_path"], identity["launch_id"], %{"tree_drained" => false})
    assert stop_and_confirm(identity).status == :TERMINATION_UNCONFIRMED
    assert %{status: :TERMINATION_UNCONFIRMED} = Orchestrator.managed_receipt_confirmation_for_test(identity)
    assert WorkerContainment.verify_identity_receipt(identity) == {:error, :unknown}

    write_receipt(identity["receipt_path"], identity["launch_id"], %{"terminal_reason" => "WRAPPER_FAILURE"})
    assert stop_and_confirm(identity).status == :TERMINATION_UNCONFIRMED
    assert %{status: :TERMINATION_UNCONFIRMED} = Orchestrator.managed_receipt_confirmation_for_test(identity)

    write_receipt(identity["receipt_path"], identity["launch_id"], %{"terminal_reason" => "ROOT_EXITED"})
    assert stop_and_confirm(identity).status == :TERMINATION_UNCONFIRMED

    File.write!(
      identity["receipt_path"],
      Jason.encode!(Map.put(valid_body(identity["launch_id"]), "tree_drained", "yes"))
    )

    invalid_shape = stop_with_gone_wrapper(identity)
    assert invalid_shape.status == :TERMINATION_UNCONFIRMED
    assert invalid_shape.receipt == nil
    assert Orchestrator.managed_receipt_confirmation_for_test(identity) == nil
  end

  test "a matched receipt still clears the LaunchMarker and allows managed reuse" do
    identity = new_identity("issue-clear")
    assert :ok = LaunchMarker.record(identity, identifier: "CLR-1")
    write_receipt(identity["receipt_path"], identity["launch_id"], %{"child_exit_code" => 0})

    assert :allowed = LaunchMarker.cleanup_gate(identity["issue_id"])

    confirmation = AppServer.stop_session(%{port: open_port(), worker_identity: identity})

    assert confirmation.status == :TERMINATED_CONFIRMED
    assert WorkerContainment.reuse_gate(confirmation, :MANAGED_CONFIRMATION_REQUIRED) == :allowed
    assert {:error, :not_found} = LaunchMarker.read(identity["issue_id"])
    assert :allowed = LaunchMarker.cleanup_gate(identity["issue_id"])
    assert %{status: :TERMINATED_CONFIRMED} = Orchestrator.managed_receipt_confirmation_for_test(identity)
  end

  defp new_identity(issue_id) do
    WorkerContainment.new_identity(
      issue_id: issue_id,
      attempt_id: 1,
      workspace: Path.join(["C:", "tmp", "ws", issue_id]),
      worker_host: nil
    )
  end

  defp valid_body(launch_id) do
    %{
      "schema_version" => 1,
      "launch_id" => launch_id,
      "tree_drained" => true,
      "terminal_reason" => "NATURAL_EXIT",
      "termination_mode" => "stdin_eof_terminate",
      "child_exit_code" => 0
    }
  end

  defp write_receipt(path, launch_id, overrides \\ %{}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.merge(valid_body(launch_id), overrides)))
    path
  end

  defp open_port do
    Port.open({:spawn, "cmd /c exit 0"}, [:binary])
  end

  defp stop_and_confirm(identity) do
    WorkerContainment.stop_and_confirm(open_port(), identity, 1)
  end

  defp stop_with_gone_wrapper(identity) do
    previous_probe = Application.get_env(:symphony_elixir, :worker_containment_tasklist_probe)
    previous_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms)

    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, 50)

    Application.put_env(:symphony_elixir, :worker_containment_tasklist_probe, fn _args ->
      {"INFO: No tasks are running which match the specified criteria.", 0}
    end)

    try do
      WorkerContainment.stop_and_confirm(open_port(), Map.put(identity, "wrapper_pid", "424242"), 1)
    after
      restore_app_env(:worker_containment_tasklist_probe, previous_probe)
      restore_app_env(:worker_termination_hard_budget_ms, previous_budget)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
