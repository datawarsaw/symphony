defmodule SymphonyElixir.ImplementationReviewTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-review-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "MIC-167")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.ex"), "implementation diff\n")
    File.write!(Path.join(workspace, "workpad.md"), "validation evidence\n")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, workspace: workspace}
  end

  test "In Review ends implementation turns and preserves source and evidence on reconciliation", %{workspace: workspace} do
    issue = %Issue{id: "review-issue", identifier: "MIC-167", state: "In Progress", labels: []}
    review = %{issue | state: "In Review"}
    assert {:done, ^review} = AgentRunner.continue_with_issue_for_test(issue, fn _ -> {:ok, [review]} end)

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(worker)

    state = %Orchestrator.State{
      running: %{issue.id => %{pid: worker, ref: nil, identifier: issue.identifier, issue: issue, workspace_path: workspace, started_at: DateTime.utc_now()}},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      claimed: MapSet.new([issue.id])
    }

    reconciled = Orchestrator.reconcile_issue_states_for_test([review], state)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    refute Map.has_key?(reconciled.running, issue.id)
    refute MapSet.member?(reconciled.claimed, issue.id)
    assert File.read!(Path.join(workspace, "source.ex")) == "implementation diff\n"
    assert File.read!(Path.join(workspace, "workpad.md")) == "validation evidence\n"
  end

  test "retry lookup releases In Review without removing the recorded workspace", %{workspace: workspace} do
    review = %Issue{id: "review-retry", identifier: "MIC-167", state: "In Review", labels: []}
    state = %Orchestrator.State{claimed: MapSet.new([review.id])}
    released = Orchestrator.handle_retry_issue_lookup_for_test(review, state, review.id, 1, %{identifier: review.identifier, workspace_path: workspace, worker_host: nil})
    refute MapSet.member?(released.claimed, review.id)
    assert File.read!(Path.join(workspace, "source.ex")) == "implementation diff\n"
    assert File.read!(Path.join(workspace, "workpad.md")) == "validation evidence\n"
  end

  test "shipped workflow leaves review outside dispatch and terminal cleanup states" do
    assert {:ok, %{config: config}} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))
    refute "In Review" in config["tracker"]["active_states"]
    refute "In Review" in config["tracker"]["terminal_states"]
    refute "Merging" in config["tracker"]["active_states"]
    assert config["codex"]["thread_sandbox"] == "workspace-write"
  end
end
