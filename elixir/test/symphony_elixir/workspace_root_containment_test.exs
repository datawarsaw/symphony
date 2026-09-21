defmodule SymphonyElixir.WorkspaceRootContainmentTest do
  # Destructive-operation guard for test temp-root safety: every cleanup target
  # a test hands to the lifecycle must live strictly inside a test-owned fixture
  # root, and the shared system TEMP root must never be declared as the trusted
  # deletion boundary. These tests drive the production cleanup paths themselves
  # (`Workspace.remove_recorded/3` and the orchestrator terminal reconcile) and
  # prove a foreign sentinel outside the owned root survives.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue

  # Production init seeds the token totals with an empty map; the bare struct
  # leaves it nil, which the completion paths read.
  @empty_codex_totals %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}

  defp fresh_state, do: %Orchestrator.State{codex_totals: @empty_codex_totals}

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Workspace root containment " <> identifier,
      description: "test temp root safety",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp owned_root!(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "workspace-root-containment-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> SymphonyElixir.TestSupport.remove_temp_fixture_root!(root) end)
    root
  end

  # A foreign file directly under the system TEMP root, outside every test-owned
  # fixture root. Each guard proves the lifecycle cleanup never touches it.
  defp foreign_sentinel! do
    path =
      Path.join(System.tmp_dir!(), "sentinel-not-owned-#{System.unique_integer([:positive])}.txt")

    File.write!(path, "foreign sentinel: no test fixture owns the TEMP root\n")
    path
  end

  describe "Workspace.remove_recorded containment (production cleanup path)" do
    test "removes a strict child of the recorded root and nothing outside it" do
      owned_root = owned_root!("strict-child")
      workspace = Path.join(owned_root, "ws-guard")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "work.md"), "owned work\n")

      sentinel = foreign_sentinel!()

      try do
        assert {:ok, _removed} = Workspace.remove_recorded(workspace, nil, owned_root)
        refute File.exists?(workspace)
        assert File.exists?(owned_root)
        assert File.exists?(sentinel)
      after
        File.rm(sentinel)
      end
    end

    test "fails closed when the recorded root itself is the removal target" do
      owned_root = owned_root!("root-itself")
      sentinel = foreign_sentinel!()

      try do
        assert {:error, {:workspace_equals_root, _workspace, _root}, ""} =
                 Workspace.remove_recorded(owned_root, nil, owned_root)

        assert File.exists?(owned_root)
        assert File.exists?(sentinel)
      after
        File.rm(sentinel)
      end
    end
  end

  describe "orchestrator lifecycle cleanup stays inside the owned root" do
    test "terminal reconcile removes the owned workspace and spares the foreign sentinel" do
      issue = test_issue("ISS-ROOT-CONTAIN", "MT-ROOT-CONTAIN")
      workspace_root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
      workspace = Path.join(workspace_root, "ws-" <> issue.id)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "work.md"), "owned work\n")

      sentinel = foreign_sentinel!()

      # The same running-entry shape the fallback-routing fixtures hand to the
      # lifecycle: workspace_root is the boundary cleanup is trusted to delete
      # inside, and reconcile hands the whole entry to the fenced cleanup.
      entry = %{
        pid: spawn(fn -> Process.sleep(:infinity) end),
        ref: make_ref(),
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: workspace,
        workspace_root: workspace_root,
        started_at: DateTime.utc_now()
      }

      state = %{fresh_state() | running: Map.put(fresh_state().running, issue.id, entry)}

      try do
        next_state = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

        refute Process.alive?(entry.pid)
        refute MapSet.member?(next_state.claimed, issue.id)
        # The owned workspace was removed; the owned root and the foreign
        # sentinel outside it both survived.
        refute File.exists?(workspace)
        assert File.exists?(workspace_root)
        assert File.exists?(sentinel)
      after
        Process.exit(entry.pid, :kill)
        File.rm(sentinel)
      end
    end
  end
end
