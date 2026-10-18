defmodule SymphonyElixir.DiscoveryLaunchFenceTest do
  use SymphonyElixir.TestSupport

  # MIC-223 launch-fence propagation for the Discovery lane, proven without
  # spawning a worker.
  #
  # `AppServer.start_session/2` records the durable launch marker as the FIRST
  # step of its launch chain, and every later step (routing, workspace
  # containment, `Port.open`) is reachable only when that step returned `:ok`.
  # The marker write therefore sits strictly before worker activation, and the
  # durable state it leaves in the store is the observable that proves which
  # issue key AND which mutation root reached the launch:
  #
  #   * keyed   — `write/3` builds `<safe_issue_id>.json` and writes a
  #               `<safe_issue_id>.json.<n>.tmp` beside it; an unkeyed launch
  #               never calls the writer at all and warns "proceeding unfenced".
  #   * pinning — `LaunchMarker.root/1` honours the `:root` option (the
  #               boot-pinned authority root) and `clear/1` removes only the
  #               file, never the store directory it was written into.
  #
  # Real child-process launches are unavailable in the environments this suite
  # runs in, so fail-closed refusals carry the ordering evidence instead of a
  # started process.

  alias SymphonyElixir.{Discovery, RetryStore, WorkerContainment, WorkflowStore}

  @skip_reason if(match?({:win32, _}, :os.type()),
                 do: false,
                 else: "Managed containment is Windows-only"
               )

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(root)
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    skill = Path.join(root, "skill/SKILL.md")
    File.mkdir_p!(Path.join(root, "skill/references"))
    File.write!(skill, "Read-only Discovery. SUBAGENTS: DISABLED")
    File.write!(Path.join(root, "skill/references/discovery-contract.md"), "DISCOVERY BRIEF and TODO HANDOFF")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 600_000,
      workspace_root: Path.join(root, "workspaces"),
      routing: %{"targets" => %{"symphony" => %{"source_path" => source}}},
      codex_worker_containment_enabled: true,
      codex_command: "must-not-launch-discovery-fence"
    )

    enable_discovery!(skill)

    # The fence stores must resolve from the pinned authority root, so neither
    # app-env override may outrank it while these tests run.
    Application.delete_env(:symphony_elixir, :launch_marker_root)
    Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)

    pinned = create_temp_fixture_root!("symphony-discovery-fence-pinned")
    on_exit(fn -> remove_temp_fixture_root!(pinned) end)

    %{issue: discovery_issue(), pinned: pinned, live: Config.local_workspace_root()}
  end

  @tag skip: @skip_reason
  test "authority_root routes the issue-keyed marker write into the pinned store and refuses the launch",
       %{issue: issue, pinned: pinned, live: live} do
    assert WorkerContainment.contained_launch?(nil),
           "the regression needs managed containment active to reach the launch marker"

    launches = launches_dir(pinned)
    File.mkdir_p!(launches)

    key = RetryStore.safe_issue_id(issue.id)

    # A directory at the marker path fails the atomic rename (`:eisdir`) AFTER
    # the store directory exists and the temp file is written, so the refusal is
    # attributable to this exact keyed path in this exact store.
    File.mkdir_p!(Path.join(launches, key <> ".json"))

    log =
      capture_log(fn ->
        assert {:error, {:discovery_technical_failure, _}} = Discovery.run(issue, self(), authority_root: pinned)
        issue_id = issue.id
        refute_receive {:discovery_completed, ^issue_id, _}
      end)

    # Keyed: the marker writer saw the real issue id, so Discovery threaded the
    # issue into the session options instead of leaving it nil.
    assert log =~ "Launch marker reuse refused issue_id=#{issue.id}"
    refute log =~ "proceeding unfenced"

    # The writer staged the marker beside exactly the issue-keyed path it was
    # renaming onto, and the refusal came from that collision.
    assert [] = Enum.filter(File.ls!(launches), &String.ends_with?(&1, ".tmp"))
    assert log =~ "launch_marker_unreadable"

    # Fail closed: no marker was durably installed and the launch never became
    # materially active, because the write that gates activation is what failed.
    assert File.dir?(Path.join(launches, key <> ".json"))
    refute_received {:codex_worker_update, _, _}

    # Pinned root: the live configuration root was never consulted for the fence.
    refute File.exists?(launches_dir(live))
  end

  @tag skip: @skip_reason
  test "identity-derived marker operations stay in the pinned store, not the live config root",
       %{issue: issue, pinned: pinned, live: live} do
    assert WorkerContainment.contained_launch?(nil),
           "the regression needs managed containment active to reach the launch marker"

    # A missing containment helper fails the launch after the marker is durably
    # written, which is the pre-port "never spawned" seam: the launch is refused
    # and the marker is cleared on conclusively-never-started evidence.
    helper_root = create_temp_fixture_root!("symphony-discovery-fence-helper")
    previous = Application.get_env(:symphony_elixir, :jobrun_helper_path)
    Application.put_env(:symphony_elixir, :jobrun_helper_path, Path.join(helper_root, "missing-jobrun.exe"))

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :jobrun_helper_path)
      else
        Application.put_env(:symphony_elixir, :jobrun_helper_path, previous)
      end

      remove_temp_fixture_root!(helper_root)
    end)

    key = RetryStore.safe_issue_id(issue.id)

    assert {:error, {:discovery_technical_failure, _}} = Discovery.run(issue, self(), authority_root: pinned)
    issue_id = issue.id
    refute_receive {:discovery_completed, ^issue_id, _}

    # The store directory exists because the keyed marker write created it, and
    # it is empty because the clear that followed the refusal removed exactly
    # that marker — so both operations resolved to this same pinned store.
    launches = launches_dir(pinned)
    assert File.dir?(launches), "the keyed marker write must create its store under the pinned root"
    assert File.ls!(launches) == []
    refute File.regular?(Path.join(launches, key <> ".json"))

    # Nothing was ever fenced in the live configuration root's stores.
    refute File.exists?(launches_dir(live))
    refute File.exists?(Path.join([live, ".symphony-state", "worker-terminations"]))
    refute_received {:codex_worker_update, _, _}
  end

  defp launches_dir(root), do: Path.join([root, ".symphony-state", "launches"])

  defp enable_discovery!(skill) do
    body = File.read!(Workflow.workflow_file_path())

    body =
      String.replace(
        body,
        "---",
        "---\ndiscovery:\n  enabled: true\n  skill_path: #{Jason.encode!(skill)}",
        global: false
      )

    File.write!(Workflow.workflow_file_path(), body)
    WorkflowStore.force_reload()
  end

  defp discovery_issue do
    %Issue{
      id: "discovery-launch-fence-issue",
      identifier: "MIC-FENCE",
      title: "Dedicated Discovery worker",
      description: "Inspect the bounded lane",
      state: "Discovery",
      labels: ["repo:symphony"],
      dispatchable: true,
      parent: %{"identifier" => "MIC-PARENT"},
      project: %{"name" => "Symphony"}
    }
  end
end
