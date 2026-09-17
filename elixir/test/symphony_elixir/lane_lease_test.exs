defmodule SymphonyElixir.LaneLeaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LaneLease

  @issue "MIC-999"
  @kind "delivery"

  setup do
    root = Path.join(System.tmp_dir!(), "mic-lane-lease-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp claim_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: @issue,
        owner_id: "executor-a",
        worktree_path: "C:/wt/mic-999",
        branch: "symphony/MIC-999",
        accepted_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      },
      overrides
    )
  end

  defp iso(seconds_ago) do
    DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp raw_lease(root) do
    LaneLease.lease_path(root, @kind, @issue) |> File.read!() |> Jason.decode!()
  end

  defp write_raw_lease(root, lease) do
    File.write!(LaneLease.lease_path(root, @kind, @issue), Jason.encode!(lease, pretty: true))
  end

  defp backdate_heartbeat(root, seconds_ago) do
    root |> raw_lease() |> Map.put("heartbeat_at", iso(seconds_ago)) |> then(&write_raw_lease(root, &1))
  end

  # 1. first claimant succeeds
  test "first claimant succeeds and persists the full lease", %{root: root} do
    assert {:ok, lease} = LaneLease.claim(root, claim_attrs())
    assert is_binary(lease["owner_token"]) and byte_size(lease["owner_token"]) >= 32
    assert lease["lane_id"] == "delivery:#{@issue}"
    assert lease["lane_kind"] == @kind

    persisted = raw_lease(root)

    for field <- ~w(lane_id lane_kind issue_id owner_token owner_id worktree_path branch accepted_sha base_sha created_at heartbeat_at) do
      assert is_binary(Map.fetch!(persisted, field)) and Map.fetch!(persisted, field) != "", "field #{field}"
    end

    assert persisted["accepted_sha"] == String.duplicate("a", 40)
    assert persisted["base_sha"] == String.duplicate("b", 40)
  end

  # 2. second owner for same lane is rejected
  test "second claimant for the same lane is rejected with evidence and no token leak", %{root: root} do
    {:ok, _lease} = LaneLease.claim(root, claim_attrs())

    assert {:error, {:lease_held, evidence}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))
    assert evidence["owner_id"] == "executor-a"
    assert evidence["class"] == "active"
    refute Map.has_key?(evidence, "owner_token")
  end

  # 3. same owner can inspect/renew
  test "owner can inspect and renew the lease", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())

    assert {:ok, evidence} = LaneLease.inspect(root, @kind, @issue)
    assert evidence["owner_id"] == "executor-a"

    assert {:ok, renewed} = LaneLease.renew(root, @kind, @issue, lease["owner_token"])
    assert renewed["heartbeat_at"] >= lease["heartbeat_at"]
    assert raw_lease(root)["heartbeat_at"] == renewed["heartbeat_at"]
  end

  # 4. foreign owner cannot renew
  test "foreign owner cannot renew", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())

    assert {:error, :not_owner} = LaneLease.renew(root, @kind, @issue, String.duplicate("f", 32))
    assert raw_lease(root)["heartbeat_at"] == lease["heartbeat_at"]
    assert raw_lease(root)["owner_token"] == lease["owner_token"]
  end

  # 5. foreign owner cannot release
  test "foreign owner cannot release", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())

    assert {:error, :not_owner} = LaneLease.release(root, @kind, @issue, String.duplicate("f", 32))
    assert {:ok, evidence} = LaneLease.inspect(root, @kind, @issue)
    assert evidence["owner_id"] == "executor-a"
    assert raw_lease(root)["owner_token"] == lease["owner_token"]
  end

  # 6. accepted SHA mismatch fails closed (cannot silently continue as B)
  test "accepted SHA cannot silently change on a held lane", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())

    other_sha = String.duplicate("c", 40)
    assert {:error, {:lease_held, _}} = LaneLease.claim(root, claim_attrs(%{accepted_sha: other_sha}))
    assert raw_lease(root)["accepted_sha"] == lease["accepted_sha"]

    # renew carries no binding fields: the artifact cannot move through a heartbeat
    {:ok, _} = LaneLease.renew(root, @kind, @issue, lease["owner_token"])
    assert raw_lease(root)["accepted_sha"] == lease["accepted_sha"]

    assert {:error, {:binding_mismatch, [:accepted_sha]}} = LaneLease.verify_binding(lease, %{accepted_sha: other_sha})
  end

  # 7. branch mismatch is detected
  test "branch mismatch is detected", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())
    assert {:error, {:binding_mismatch, [:branch]}} = LaneLease.verify_binding(lease, %{branch: "symphony/other"})
    assert :ok = LaneLease.verify_binding(lease, %{branch: lease["branch"], accepted_sha: lease["accepted_sha"]})
  end

  # 8. worktree mismatch is detected
  test "worktree mismatch is detected (separator and case tolerant on equal paths)", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())
    assert {:error, {:binding_mismatch, [:worktree_path]}} = LaneLease.verify_binding(lease, %{worktree_path: "C:/wt/other"})
    assert :ok = LaneLease.verify_binding(lease, %{worktree_path: "c:\\wt\\mic-999"})
  end

  # 9. corrupt lease state fails closed
  test "corrupt lease state fails closed for every operation", %{root: root} do
    path = LaneLease.lease_path(root, @kind, @issue)
    File.mkdir_p!(LaneLease.lanes_dir(root))
    File.write!(path, "not json{{{")
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.claim(root, claim_attrs())
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.inspect(root, @kind, @issue)
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.renew(root, @kind, @issue, String.duplicate("f", 32))
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.release(root, @kind, @issue, String.duplicate("f", 32))
    assert File.exists?(path)
  end

  # 10. partial lease file/write cannot fabricate ownership
  test "partial or forged lease files cannot fabricate ownership", %{root: root} do
    path = LaneLease.lease_path(root, @kind, @issue)
    File.mkdir_p!(LaneLease.lanes_dir(root))

    # a) truncated mid-write payload (valid JSON prefix, invalid JSON)
    full = Jason.encode!(LaneLease.build_lease(claim_attrs()), pretty: true)
    File.write!(path, binary_part(full, 0, div(byte_size(full), 2)))
    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))

    # b) valid JSON with a future schema version
    File.write!(path, Jason.encode!(%{"schema_version" => 2, "lane_id" => "delivery:#{@issue}"}))
    assert {:error, {:lease_state_invalid, :ambiguous_state}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))

    # c) schema-valid JSON missing required fields (no owner_token)
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "lane_id" => "delivery:#{@issue}", "issue_id" => @issue}))
    assert {:error, {:lease_state_invalid, :schema_invalid}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))

    # d) full-format lease naming a different lane parked at this lane's path
    foreign = LaneLease.build_lease(claim_attrs(%{issue_id: "MIC-OTHER"}))
    File.write!(path, Jason.encode!(foreign, pretty: true))
    assert {:error, {:lease_state_invalid, :lane_mismatch}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))
    assert {:error, {:lease_state_invalid, :lane_mismatch}} = LaneLease.inspect(root, @kind, @issue)
  end

  # 11. restart can reconstruct lane ownership from durable state
  test "a fresh process reconstructs ownership purely from durable state", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())
    assert raw_lease(root)["owner_token"] == lease["owner_token"]

    result =
      Task.async(fn ->
        with {:ok, evidence} <- LaneLease.inspect(root, @kind, @issue),
             {:ok, _renewed} <- LaneLease.renew(root, @kind, @issue, lease["owner_token"]) do
          {:ok, evidence["owner_id"]}
        end
      end)
      |> Task.await()

    assert {:ok, "executor-a"} = result
  end

  # 12. stale heartbeat does NOT silently authorize takeover
  test "stale heartbeat classifies as releasable but still rejects a new claimant", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())
    backdate_heartbeat(root, 13 * 60 * 60)

    assert {:ok, :releasable} = LaneLease.classify(raw_lease(root))

    assert {:ok, evidence} = LaneLease.inspect(root, @kind, @issue)
    assert evidence["class"] == "releasable"

    assert {:error, {:lease_held, evidence}} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))
    assert evidence["class"] == "releasable"
    assert evidence["owner_id"] == "executor-a"
    assert raw_lease(root)["owner_token"] == lease["owner_token"]
  end

  test "classify/3 separates active, stale_unconfirmed, and releasable", %{root: root} do
    {:ok, lease} = LaneLease.claim(root, claim_attrs())
    now = DateTime.utc_now()

    active = Map.put(lease, "heartbeat_at", iso(5 * 60))
    stale = Map.put(lease, "heartbeat_at", iso(60 * 60))
    gone = Map.put(lease, "heartbeat_at", iso(13 * 60 * 60))

    assert {:ok, :active} = LaneLease.classify(active, now)
    assert {:ok, :stale_unconfirmed} = LaneLease.classify(stale, now)
    assert {:ok, :releasable} = LaneLease.classify(gone, now)
  end

  # 13. two concurrent claim attempts produce exactly one winner
  test "concurrent claimants produce exactly one winner, losers fail closed", %{root: root} do
    results =
      1..12
      |> Task.async_stream(fn i ->
        LaneLease.claim(root, claim_attrs(%{owner_id: "executor-#{i}"}))
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    winners = Enum.filter(results, &match?({:ok, _}, &1))
    losers = Enum.filter(results, &match?({:error, _}, &1))

    assert length(winners) == 1
    assert length(losers) == 11
    {:ok, winner} = Enum.find(winners, &match?({:ok, _}, &1))
    assert raw_lease(root)["owner_token"] == winner["owner_token"]
    assert raw_lease(root)["owner_id"] == winner["owner_id"]
  end

  # 14. separate issue/lane identities do not block each other
  test "separate lane identities do not block each other", %{root: root} do
    {:ok, lease_a} = LaneLease.claim(root, claim_attrs(%{issue_id: "MIC-A", branch: "symphony/MIC-A"}))
    {:ok, lease_b} = LaneLease.claim(root, claim_attrs(%{issue_id: "MIC-B", branch: "symphony/MIC-B"}))

    assert :ok = LaneLease.release(root, @kind, "MIC-A", lease_a["owner_token"])
    assert {:error, :not_found} = LaneLease.inspect(root, @kind, "MIC-A")

    assert {:ok, _} = LaneLease.renew(root, @kind, "MIC-B", lease_b["owner_token"])
    assert {:ok, _} = LaneLease.claim(root, claim_attrs(%{issue_id: "MIC-A", branch: "symphony/MIC-A", owner_id: "executor-c"}))
  end

  # operator recovery semantics
  test "force_release requires explicit confirmation and a reason", %{root: root} do
    {:ok, _} = LaneLease.claim(root, claim_attrs())
    assert {:error, :recovery_unconfirmed} = LaneLease.force_release(root, @kind, @issue, reason: "x")
    assert {:error, :recovery_reason_required} = LaneLease.force_release(root, @kind, @issue, confirm: true)
    assert {:error, :recovery_reason_required} = LaneLease.force_release(root, @kind, @issue, confirm: true, reason: "")
    assert {:ok, _} = LaneLease.inspect(root, @kind, @issue)
  end

  test "force_release clears a held lane, preserves evidence, and unblocks a new claim", %{root: root} do
    {:ok, _} = LaneLease.claim(root, claim_attrs())

    assert {:ok, record} =
             LaneLease.force_release(root, @kind, @issue,
               confirm: true,
               reason: "operator: owner host lost mid-delivery",
               forced_by: "operator-console"
             )

    assert record["reason"] == "operator: owner host lost mid-delivery"
    assert record["prior_state"]["owner_id"] == "executor-a"
    assert record["prior_state"]["accepted_sha"] == String.duplicate("a", 40)

    recovery_path = Path.join(LaneLease.lanes_dir(root), "delivery_mic-999.recovery.json")
    assert File.exists?(recovery_path)
    assert {:error, :not_found} = LaneLease.inspect(root, @kind, @issue)

    assert {:ok, _} = LaneLease.claim(root, claim_attrs(%{owner_id: "executor-b"}))
  end

  test "force_release recovers corrupt state (the only way through it)", %{root: root} do
    File.mkdir_p!(LaneLease.lanes_dir(root))
    File.write!(LaneLease.lease_path(root, @kind, @issue), "garbage{{{")

    assert {:error, {:lease_state_invalid, :corrupt_state}} = LaneLease.claim(root, claim_attrs())

    assert {:ok, record} = LaneLease.force_release(root, @kind, @issue, confirm: true, reason: "operator: corrupt state")
    assert is_binary(record["prior_state"])

    assert {:ok, _} = LaneLease.claim(root, claim_attrs())
  end

  test "force_release on a free lane is lease_missing", %{root: root} do
    assert {:error, :lease_missing} = LaneLease.force_release(root, @kind, @issue, confirm: true, reason: "x")
  end

  test "claim rejects malformed attributes", %{root: root} do
    assert {:error, :invalid_attrs} = LaneLease.claim(root, %{})
    assert {:error, :invalid_attrs} = LaneLease.claim(root, claim_attrs(%{accepted_sha: ""}))
    assert {:error, :invalid_attrs} = LaneLease.claim(root, claim_attrs(%{lane_kind: "Bad Kind"}))
    assert {:error, :invalid_attrs} = LaneLease.claim(:not_a_root, %{"x" => 1})
  end

  # live git binding verification
  describe "verify_live_state/2 against a real git worktree" do
    setup %{root: root} do
      repo = Path.join(root, "repo-wt")
      File.mkdir_p!(repo)
      git!(repo, ["init", "-b", "main"])
      File.write!(Path.join(repo, "f.txt"), "one")
      git!(repo, ["add", "."])
      git!(repo, ["-c", "user.name=lane-test", "-c", "user.email=lane@test", "commit", "-m", "base"])
      base = rev(repo)
      git!(repo, ["checkout", "-b", "symphony/delivery-mic-999"])
      File.write!(Path.join(repo, "f.txt"), "two")
      git!(repo, ["add", "."])
      git!(repo, ["-c", "user.name=lane-test", "-c", "user.email=lane@test", "commit", "-m", "accepted"])
      accepted = rev(repo)

      lease =
        LaneLease.build_lease(%{
          issue_id: @issue,
          owner_id: "executor-a",
          worktree_path: repo,
          branch: "symphony/delivery-mic-999",
          accepted_sha: accepted,
          base_sha: base
        })

      {:ok, repo: repo, lease: lease, base: base, accepted: accepted}
    end

    test "matching live state verifies clean", %{lease: lease} do
      assert :ok = LaneLease.verify_live_state(lease)
      assert :ok = LaneLease.verify_live_state(lease, accepted_sha: lease["accepted_sha"])
      assert :ok = LaneLease.verify_live_state(lease, require_accepted_in_head: true)
    end

    test "branch drift and foreign artifact fail closed", %{repo: repo, lease: lease, base: base} do
      assert {:error, {:binding_mismatch, fields}} = LaneLease.verify_live_state(lease, accepted_sha: String.duplicate("d", 40))
      assert "accepted_sha" in fields

      git!(repo, ["checkout", "main"])

      assert {:error, {:binding_mismatch, fields}} = LaneLease.verify_live_state(lease, require_accepted_in_head: true)
      assert "branch" in fields
      assert "accepted_sha in HEAD" in fields

      # rebase-style divergence: leased base no longer an ancestor of HEAD
      git!(repo, ["checkout", "--orphan", "diverged"])
      File.write!(Path.join(repo, "g.txt"), "diverged")
      git!(repo, ["add", "."])
      git!(repo, ["-c", "user.name=lane-test", "-c", "user.email=lane@test", "commit", "-m", "orphan"])
      assert {:error, {:binding_mismatch, fields}} = LaneLease.verify_live_state(%{lease | "base_sha" => base})
      assert "base_sha" in fields
    end

    test "observe_worktree reports branch and HEAD", %{repo: repo, lease: lease} do
      assert {:ok, %{branch: "symphony/delivery-mic-999", head_sha: head}} = LaneLease.observe_worktree(repo)
      assert head == lease["accepted_sha"]
      assert {:error, {:git_failed, _}} = LaneLease.observe_worktree(Path.join(repo, "missing"))
    end
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-c", "safe.directory=#{dir}", "-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp rev(dir), do: String.trim(git!(dir, ["rev-parse", "HEAD"]))
end
