defmodule SymphonyElixir.LaunchDiagnosticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LaunchDiagnostics
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.WorkerContainment
  alias SymphonyElixirWeb.Presenter

  @moduletag :launch_diagnostics

  # Read-only diagnostics over the hardening-critical durable launch state:
  # launch marker, termination receipt, and the resume/cleanup fence verdict.
  # Every verdict asserted here is produced by the authoritative
  # implementations (LaunchMarker / WorkerFence / WorkerContainment); these
  # tests pin the projection's classification, its fail-closed rendering of
  # unproven evidence, and — via before/after content hashes — that
  # diagnostic reads never mutate durable state.

  setup do
    root =
      System.tmp_dir!()
      |> Path.expand()
      |> Path.join("symphony-launch-diagnostics-#{System.unique_integer([:positive])}")

    Application.put_env(:symphony_elixir, :launch_marker_root, root)
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(root, "receipts"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  describe "launch marker and fence diagnostics" do
    test "no marker projects ABSENT evidence with an allowed fence", %{root: root} do
      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-none")

      assert diag.marker == %{status: "ABSENT"}
      assert diag.receipt == nil
      assert diag.fence == %{decision: "ALLOWED", reason: nil}
      assert diag.store_root == root
    end

    test "valid marker with no receipt yet projects UNPROVEN, never safe" do
      identity = record_marker("issue-diag-noreceipt")

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-noreceipt")

      assert diag.marker.status == "VALID"
      assert diag.marker.launch_id == identity["launch_id"]
      assert diag.marker.identity_authority_root == nil
      assert diag.receipt.status == "ABSENT"
      assert diag.receipt.verdict == "UNKNOWN"
      assert diag.fence == %{decision: "BLOCKED", reason: "worker_termination_unproven"}
    end

    test "corrupt marker projects INVALID and a blocked fence" do
      record_marker("issue-diag-corrupt")
      path = LaunchMarker.marker_path("issue-diag-corrupt")
      File.write!(path, "{not json")

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-corrupt")

      assert diag.marker.status == "INVALID"
      assert diag.receipt == nil
      assert diag.fence == %{decision: "BLOCKED", reason: "launch_marker_unreadable"}
    end

    test "matching drained receipt proves termination and admits the fence" do
      identity = record_marker("issue-diag-proven")
      write_receipt(identity["launch_id"])

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-proven")

      assert diag.receipt.status == "VALID"
      assert diag.receipt.launch_id_matches_marker == true
      assert diag.receipt.tree_drained == true
      assert diag.receipt.terminal_reason == "NATURAL_EXIT"
      assert diag.receipt.verdict == "DEAD"
      assert diag.fence == %{decision: "ALLOWED", reason: nil}
    end

    test "matching undrained receipt stays unproven" do
      identity = record_marker("issue-diag-undrained")
      write_receipt(identity["launch_id"], %{"tree_drained" => false})

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-undrained")

      assert diag.receipt.status == "VALID"
      assert diag.receipt.launch_id_matches_marker == true
      assert diag.receipt.verdict == "UNKNOWN"
      assert diag.fence == %{decision: "BLOCKED", reason: "worker_termination_unproven"}
    end

    test "mismatched receipt launch id fails closed" do
      identity = record_marker("issue-diag-mismatch")
      write_receipt_at(identity["receipt_path"], "foreign-launch-id")

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-mismatch")

      assert diag.receipt.status == "VALID"
      assert diag.receipt.launch_id == "foreign-launch-id"
      assert diag.receipt.launch_id_matches_marker == false
      assert diag.receipt.verdict == "UNKNOWN"
      assert diag.fence == %{decision: "BLOCKED", reason: "worker_termination_unproven"}
    end

    test "malformed receipt projects INVALID, never a safe fence" do
      identity = record_marker("issue-diag-malformed")
      write_receipt(identity["launch_id"])
      File.write!(receipt_path(identity["launch_id"]), "{nope")

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-malformed")

      assert diag.receipt.status == "INVALID"
      assert diag.receipt.verdict == "UNKNOWN"
      assert diag.fence == %{decision: "BLOCKED", reason: "worker_termination_unproven"}
    end

    test "unreadable receipt evidence projects UNREADABLE and stays blocked" do
      identity = record_marker("issue-diag-unreadable")
      File.mkdir_p(receipt_path(identity["launch_id"]))

      diag = LaunchDiagnostics.issue_diagnostics("issue-diag-unreadable")

      assert diag.receipt.status == "UNREADABLE"
      assert diag.receipt.verdict == "UNKNOWN"
      assert diag.fence == %{decision: "BLOCKED", reason: "worker_termination_unproven"}
    end
  end

  describe "root drift" do
    test "diagnostics read the store root the runtime fence reads, never another root" do
      root_a =
        System.tmp_dir!()
        |> Path.expand()
        |> Path.join("symphony-launch-diagnostics-a-#{System.unique_integer([:positive])}")

      root_b =
        System.tmp_dir!()
        |> Path.expand()
        |> Path.join("symphony-launch-diagnostics-b-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf([root_a, root_b]) end)

      # Pin roots explicitly, like a lease-bound runtime does: with no
      # `:launch_marker_root` override in play, the explicit root decides —
      # for the fences and for these diagnostics alike.
      Application.delete_env(:symphony_elixir, :launch_marker_root)

      identity = record_marker("issue-diag-drift", root_a)
      write_receipt_at(identity["receipt_path"], identity["launch_id"])

      # A runtime pinned to root B fences over root B's store: the marker
      # written under root A is invisible to it, and diagnostics must report
      # exactly that — never read root A and render the stale marker as the
      # fenced state.
      drifted = LaunchDiagnostics.issue_diagnostics("issue-diag-drift", root: root_b)

      assert drifted.marker.status == "ABSENT"
      assert drifted.fence.decision == "ALLOWED"
      assert drifted.store_root == launches_dir(root_b)

      # Read under the root the launch actually used, the marker projects with
      # the authority root its identity carried, exposing the A→B drift.
      origin = LaunchDiagnostics.issue_diagnostics("issue-diag-drift", root: root_a)

      assert origin.marker.status == "VALID"
      assert origin.marker.identity_authority_root == root_a
      assert origin.store_root == launches_dir(root_a)
    end
  end

  describe "read-only invariant" do
    test "diagnostic reads mutate no durable state", %{root: root} do
      proven = record_marker("issue-diag-ro-proven")
      write_receipt(proven["launch_id"])
      record_marker("issue-diag-ro-unproven")

      corrupt_path = LaunchMarker.marker_path("issue-diag-ro-corrupt")
      File.mkdir_p!(Path.dirname(corrupt_path))
      File.write!(corrupt_path, "{stale bytes")

      before = hash_tree(root)

      for issue_id <- ~w(issue-diag-ro-proven issue-diag-ro-unproven issue-diag-ro-corrupt issue-diag-ro-absent) do
        assert is_map(LaunchDiagnostics.issue_diagnostics(issue_id))
      end

      assert hash_tree(root) == before
    end
  end

  describe "observability API projection" do
    test "state payload gains launch diagnostics without changing existing projections" do
      running_issue = test_issue("issue-diag-run", "MT-9310")
      {:ok, pid} = start_orchestrator(:diag_state)

      inject_state(pid, %{
        running: %{"issue-diag-run" => running_entry(running_issue, :primary)},
        parked: %{"issue-diag-parked" => parked_entry("MT-9311", :worker_launch_unproven)}
      })

      payload = Presenter.state_payload(Module.concat(__MODULE__, :diag_state), 5_000)

      # Existing projections unchanged in name and shape (additive-only check).
      for key <- ~w(generated_at counts operational_status running retrying blocked steering codex_totals rate_limits runtime_authority)a do
        assert Map.has_key?(payload, key)
      end

      assert MapSet.new(Map.keys(payload.launch_diagnostics)) ==
               MapSet.new(["issue-diag-run", "issue-diag-parked"])

      assert payload.launch_diagnostics["issue-diag-run"].marker.status == "ABSENT"
      assert {:ok, _json} = Jason.encode(payload)
    end

    test "issue payload gains launch diagnostics for its durable issue id" do
      {:ok, _pid} = start_orchestrator(:diag_issue)

      inject_state(Module.concat(__MODULE__, :diag_issue), %{
        parked: %{"issue-diag-issue" => parked_entry("MT-9312", :worker_launch_unproven)}
      })

      assert {:ok, body} = Presenter.issue_payload("MT-9312", Module.concat(__MODULE__, :diag_issue), 5_000)

      for key <- ~w(issue_identifier issue_id status operational_status workspace attempts running retry blocked parked logs recent_events last_error tracked)a do
        assert Map.has_key?(body, key)
      end

      assert body.issue_id == "issue-diag-issue"
      assert body.launch_diagnostics.marker.status == "ABSENT"
      assert body.launch_diagnostics.fence.decision == "ALLOWED"
    end

    test "a corrupt marker for a tracked issue does not crash the state payload" do
      {:ok, pid} = start_orchestrator(:diag_corrupt)

      inject_state(pid, %{
        parked: %{"issue-diag-corrupt-api" => parked_entry("MT-9313", :worker_launch_unproven)}
      })

      path = LaunchMarker.marker_path("issue-diag-corrupt-api")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{hand corrupted")

      payload = Presenter.state_payload(Module.concat(__MODULE__, :diag_corrupt), 5_000)

      diag = payload.launch_diagnostics["issue-diag-corrupt-api"]
      assert diag.marker.status == "INVALID"
      assert diag.fence == %{decision: "BLOCKED", reason: "launch_marker_unreadable"}
      assert {:ok, _json} = Jason.encode(payload)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp new_identity(issue_id, overrides) do
    Map.merge(
      WorkerContainment.new_identity(
        issue_id: issue_id,
        attempt_id: 1,
        workspace: Path.join(["C:", "tmp", "ws", issue_id]),
        worker_host: nil
      ),
      overrides
    )
  end

  defp record_marker(issue_id, root \\ nil) do
    overrides = if root, do: %{"authority_root" => root}, else: %{}
    opts = if root, do: [root: root], else: []
    identity = new_identity(issue_id, overrides)

    assert :ok = LaunchMarker.record(identity, Keyword.merge(opts, identifier: "MT-" <> issue_id))

    identity
  end

  defp write_receipt(launch_id, overrides \\ %{}) do
    write_receipt_at(receipt_path(launch_id), launch_id, overrides)
  end

  defp write_receipt_at(path, launch_id, overrides \\ %{}) do
    File.mkdir_p!(Path.dirname(path))

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

    File.write!(path, Jason.encode!(receipt))
    path
  end

  defp receipt_path(launch_id) do
    Path.join(Application.get_env(:symphony_elixir, :worker_termination_receipt_root), launch_id <> ".json")
  end

  defp launches_dir(root), do: Path.join([root, ".symphony-state", "launches"])

  # Relative path => SHA-256 of every file under root (dot-inclusive), so any
  # create/delete/rewrite of durable state during diagnostic reads shows up.
  defp hash_tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path ->
      {:ok, bytes} = File.read(path)
      {path, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end)
  end

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Launch diagnostics " <> identifier,
      description: "Hardening observability projection",
      state: "In Progress",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp start_orchestrator(tag) do
    orchestrator_name = Module.concat(__MODULE__, tag)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    {:ok, pid}
  end

  defp inject_state(pid, overrides) do
    initial_state = :sys.get_state(pid)
    :sys.replace_state(pid, fn _ -> Map.merge(initial_state, overrides) end)
    :ok
  end

  defp running_entry(issue, route) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      route: route,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp parked_entry(identifier, stop_reason) do
    %{
      identifier: identifier,
      failure_class: "PROVIDER_QUOTA",
      stop_reason: stop_reason,
      attempt_count: 3,
      identical_failure_count: 1,
      first_failure_at: DateTime.to_iso8601(DateTime.utc_now()),
      last_failure_at: DateTime.to_iso8601(DateTime.utc_now()),
      error: "previous worker launch not proven terminated",
      worker_host: nil,
      workspace_path: "/tmp/ws-" <> String.downcase(identifier),
      route: :primary,
      primary_failure_count: 1,
      parked_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
